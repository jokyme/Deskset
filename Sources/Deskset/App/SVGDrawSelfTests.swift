import AppKit
import ImageIO
import DesksetCore
import DesksetDraw

enum SVGDrawSelfTests {
    private static let red = RGBA(r: 255, g: 0, b: 0)
    private static let blue = RGBA(r: 0, g: 0, b: 255)
    private static let green = RGBA(r: 0, g: 255, b: 0)
    private static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    private static let stops = [ShapeGradientStop(color: red, position: 0), ShapeGradientStop(color: blue, position: 1)]

    static func run(_ t: AppTestRunner) {
        gradientTests(t)
        clippingTests(t)
        imageTests(t)
        cacheTests(t)
    }

    private static func gradientTests(_ t: AppTestRunner) {
        t.suite("Runtime: SVG drawing: object-bounds gradients interpolate in sRGB across pixel formats and scales") {
            let gradient = SVGGradient(kind: .linear(start: .zero, end: ShapePoint(1, 0)), stops: stops)
            let draw = snapshot([path(rect(20, 10, 100, 40), fill: .gradient(gradient))])
            for scale in [1, 2] {
                for bgra in [false, true] {
                    let bitmap = try Bitmap(scale: scale, bgra: bgra)
                    SVGRenderer.draw(draw, in: bitmap.canvas, context: DrawContext(fonts: AppFontResolver()))
                    color(t, bitmap, 45, 25, RGBA(r: 190, g: 0, b: 65), tolerance: 7)
                    color(t, bitmap, 70, 25, RGBA(r: 127, g: 0, b: 128), tolerance: 7)
                    color(t, bitmap, 119, 25, blue, tolerance: 8)
                    color(t, bitmap, 15, 25, clear)
                }
            }
        }

        t.suite("Runtime: SVG drawing: gradient transforms follow their coordinate units and stroke bounds") {
            var gradient = SVGGradient(kind: .linear(start: .zero, end: ShapePoint(1, 0)),
                transform: ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 0.25, ty: 0), stops: stops)
            let bitmap = try Bitmap()
            SVGRenderer.draw(snapshot([path(rect(20, 10, 80, 30), fill: .gradient(gradient))]), in: bitmap.canvas,
                             context: DrawContext(fonts: AppFontResolver()))
            color(t, bitmap, 40, 20, red, tolerance: 8)
            color(t, bitmap, 80, 20, RGBA(r: 126, g: 0, b: 129), tolerance: 8)
            gradient.units = .userSpaceOnUse
            gradient.kind = .linear(start: ShapePoint(20, 0), end: ShapePoint(100, 0))
            gradient.transform = ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 20, ty: 0)
            var style = ShapeStrokeStyle(); style.width = 10
            let stroked = SVGRenderNode.path(SVGPathDraw(path: rect(20, 10, 80, 30), fill: .none,
                stroke: .gradient(gradient), strokeStyle: style))
            let stroke = try Bitmap()
            SVGRenderer.draw(snapshot([stroked]), in: stroke.canvas, context: DrawContext(fonts: AppFontResolver()))
            color(t, stroke, 80, 7, RGBA(r: 126, g: 0, b: 129), tolerance: 8)
            color(t, stroke, 80, 20, clear)
            t.check(stroke.pixel(16, 20).a > 240, "stroke paint extends outside the fill geometry")
        }

        t.suite("Runtime: SVG drawing: repeat and reflect include negative and distant linear periods") {
            for spread in [SVGSpreadMethod.repeat, .reflect] {
                let gradient = SVGGradient(kind: .linear(start: ShapePoint(20, 0), end: ShapePoint(40, 0)),
                    units: .userSpaceOnUse, spread: spread, stops: stops)
                let bitmap = try Bitmap()
                SVGRenderer.draw(snapshot([path(rect(0, 0, 140, 30), fill: .gradient(gradient))]), in: bitmap.canvas,
                                 context: DrawContext(fonts: AppFontResolver()))
                for x in [5, 25, 45, 85, 125] {
                    let value = (Double(x) + 0.5 - 20) / 20
                    let period = spread == .repeat ? value - floor(value) : {
                        let remainder = value - floor(value / 2) * 2
                        return remainder <= 1 ? remainder : 2 - remainder
                    }()
                    color(t, bitmap, x, 15, RGBA(r: (1 - period) * 255, g: 0, b: period * 255), tolerance: 9)
                }
            }
        }

        t.suite("Runtime: SVG drawing: radial gradients preserve focal points and nonuniform object bounds") {
            let focal = SVGGradient(kind: .radial(center: ShapePoint(60, 40), focus: ShapePoint(40, 40), radius: 30),
                                    units: .userSpaceOnUse, stops: stops)
            let bitmap = try Bitmap()
            SVGRenderer.draw(snapshot([path(rect(0, 0, 140, 80), fill: .gradient(focal))]), in: bitmap.canvas,
                             context: DrawContext(fonts: AppFontResolver()))
            color(t, bitmap, 40, 40, red, tolerance: 12)
            color(t, bitmap, 60, 40, RGBA(r: 151, g: 0, b: 104), tolerance: 9)
            color(t, bitmap, 105, 40, blue)
            let ellipse = SVGGradient(kind: .radial(center: ShapePoint(0.5, 0.5), focus: ShapePoint(0.5, 0.5), radius: 0.5),
                                      stops: stops)
            let elliptical = try Bitmap()
            SVGRenderer.draw(snapshot([path(rect(20, 10, 80, 40), fill: .gradient(ellipse))]), in: elliptical.canvas,
                             context: DrawContext(fonts: AppFontResolver()))
            color(t, elliptical, 80, 30, RGBA(r: 124, g: 0, b: 131), tolerance: 9)
            color(t, elliptical, 60, 40, RGBA(r: 121, g: 0, b: 134), tolerance: 9)
        }

        t.suite("Runtime: SVG drawing: radial spread and degenerate gradients remain defined") {
            for spread in [SVGSpreadMethod.repeat, .reflect] {
                let gradient = SVGGradient(kind: .radial(center: ShapePoint(10, 30), focus: ShapePoint(10, 30), radius: 20),
                    units: .userSpaceOnUse, spread: spread, stops: stops)
                let bitmap = try Bitmap()
                SVGRenderer.draw(snapshot([path(rect(0, 0, 140, 70), fill: .gradient(gradient))]), in: bitmap.canvas,
                                 context: DrawContext(fonts: AppFontResolver()))
                for x in [20, 40, 80, 120] {
                    let value = hypot(Double(x) + 0.5 - 10, 0.5) / 20
                    let remainder = spread == .repeat ? value - floor(value) : value - floor(value / 2) * 2
                    let p = spread == .reflect && remainder > 1 ? 2 - remainder : remainder
                    color(t, bitmap, x, 30, RGBA(r: 255 * (1 - p), g: 0, b: 255 * p), tolerance: 10)
                }
            }
            for kind in [SVGGradient.Kind.linear(start: .zero, end: .zero),
                         .radial(center: .zero, focus: .zero, radius: 0)] {
                let bitmap = try Bitmap()
                SVGRenderer.draw(snapshot([path(rect(0, 0, 40, 40), fill: .gradient(SVGGradient(kind: kind, stops: stops)))]),
                    in: bitmap.canvas, context: DrawContext(fonts: AppFontResolver()))
                color(t, bitmap, 10, 10, blue)
            }
        }

        t.suite("Runtime: SVG drawing: rotated gradients, outside focus and empty or single stops are deterministic") {
            let rotation = ShapeTransform(a: 0, b: 1, c: -1, d: 0, tx: 80, ty: 0)
            let rotated = SVGGradient(kind: .linear(start: .zero, end: ShapePoint(40, 0)),
                units: .userSpaceOnUse, transform: rotation, stops: stops)
            let bitmap = try Bitmap()
            SVGRenderer.draw(snapshot([path(rect(0, 0, 100, 60), fill: .gradient(rotated))]), in: bitmap.canvas,
                             context: DrawContext(fonts: AppFontResolver()))
            color(t, bitmap, 20, 10, RGBA(r: 188, g: 0, b: 67), tolerance: 8)
            color(t, bitmap, 60, 10, RGBA(r: 188, g: 0, b: 67), tolerance: 8)
            let focal = SVGGradient(kind: .radial(center: ShapePoint(50, 40), focus: ShapePoint(100, 40), radius: 30),
                                    units: .userSpaceOnUse, stops: stops)
            let projected = try Bitmap()
            SVGRenderer.draw(snapshot([path(rect(0, 0, 120, 80), fill: .gradient(focal))]), in: projected.canvas,
                             context: DrawContext(fonts: AppFontResolver()))
            color(t, projected, 50, 40, RGBA(r: 127, g: 0, b: 128), tolerance: 12)
            for list in [[], [ShapeGradientStop(color: green, position: 0.3)]] {
                let paint = SVGGradient(kind: .linear(start: .zero, end: ShapePoint(1, 0)), stops: list)
                let canvas = try Bitmap()
                SVGRenderer.draw(snapshot([path(rect(0, 0, 40, 40), fill: .gradient(paint))]), in: canvas.canvas,
                                 context: DrawContext(fonts: AppFontResolver()))
                color(t, canvas, 20, 20, list.isEmpty ? clear : green)
            }
        }

        t.suite("Runtime: SVG drawing: group and inherited opacity composite overlapping children once") {
            let children = [path(rect(10, 10, 40, 40), fill: .color(red)), path(rect(30, 10, 40, 40), fill: .color(red))]
            let group = SVGRenderNode.group(transform: .identity, opacity: 0.5, clip: nil, children: children)
            for inherited in [1.0, 0.5] {
                let bitmap = try Bitmap(); bitmap.canvas.setAlpha(inherited)
                SVGRenderer.draw(snapshot([group]), in: bitmap.canvas, context: DrawContext(fonts: AppFontResolver()))
                let expected = RGBA(r: 255 * 0.5 * inherited, g: 0, b: 0, a: 255 * 0.5 * inherited)
                for x in [20, 40, 60] { color(t, bitmap, x, 25, expected, tolerance: 2) }
            }
        }
    }

    private static func clippingTests(_ t: AppTestRunner) {
        t.suite("Runtime: SVG drawing: clip children union without overlap holes and retain individual fill rules") {
            var hollow = rect(10, 10, 60, 60)
            hollow.subpaths += rect(25, 25, 30, 30).subpaths
            hollow.fillRule = .evenOdd
            let clip = SVGClip(children: [.path(hollow), .path(rect(40, 30, 40, 30))])
            let node = SVGRenderNode.group(transform: .identity, opacity: 1, clip: clip,
                                          children: [path(rect(0, 0, 100, 80), fill: .color(red))])
            let bitmap = try Bitmap()
            SVGRenderer.draw(snapshot([node]), in: bitmap.canvas, context: DrawContext(fonts: AppFontResolver()))
            color(t, bitmap, 15, 15, red)
            color(t, bitmap, 30, 35, clear)
            color(t, bitmap, 45, 35, red)
            color(t, bitmap, 65, 35, red)
            color(t, bitmap, 85, 35, clear)
        }

        t.suite("Runtime: SVG drawing: object-bounds clips and nested transformed clips intersect") {
            let outer = SVGClip(units: .objectBoundingBox,
                transform: ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 0.25, ty: 0), children: [.path(rect(0, 0, 0.5, 1))])
            let inner = SVGClip(children: [.path(rect(0, 0, 100, 20))])
            let node = SVGRenderNode.group(transform: ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 10, ty: 5),
                opacity: 1, clip: outer, children: [.group(transform: .identity, opacity: 1, clip: inner,
                    children: [path(rect(0, 0, 100, 40), fill: .color(blue))])])
            let bitmap = try Bitmap()
            SVGRenderer.draw(snapshot([node]), in: bitmap.canvas, context: DrawContext(fonts: AppFontResolver()))
            color(t, bitmap, 40, 15, blue)
            color(t, bitmap, 25, 15, clear)
            color(t, bitmap, 90, 15, clear)
            color(t, bitmap, 40, 35, clear)
            let empty = SVGRenderNode.group(transform: .identity, opacity: 1, clip: SVGClip(children: []),
                                           children: [path(rect(0, 0, 40, 40), fill: .color(red))])
            let clipped = try Bitmap()
            SVGRenderer.draw(snapshot([empty]), in: clipped.canvas, context: DrawContext(fonts: AppFontResolver()))
            color(t, clipped, 20, 20, clear)
        }

        t.suite("Runtime: SVG drawing: clipping does not shrink bounds used by an outer clip on a direct use") {
            let rightHalf = SVGClip(units: .objectBoundingBox, children: [.path(rect(0.5, 0, 0.5, 1))])
            let leftSixty = SVGClip(children: [.path(rect(0, 0, 60, 100))])
            let reference = SVGClipNode.group(transform: .identity, clip: leftSixty,
                                             children: [.path(rect(0, 0, 100, 100))])
            let directUse = SVGClipNode.group(transform: .identity, clip: rightHalf, children: [reference])
            let combined = SVGClip(children: [directUse])
            let draw = snapshot([.group(transform: .identity, opacity: 1, clip: combined,
                                        children: [path(rect(0, 0, 100, 100), fill: .color(red))])])
            let bitmap = try Bitmap()
            SVGRenderer.draw(draw, in: bitmap.canvas, context: DrawContext(fonts: AppFontResolver()))
            color(t, bitmap, 35, 40, clear, "the outer right half starts at 50, not 30 of the clipped reference")
            color(t, bitmap, 55, 40, red)
            color(t, bitmap, 70, 40, clear)

            for leftWidth in [50, 60] {
                let svg = """
                <svg xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="100"><defs><clipPath id="left"><rect width="\(leftWidth)" height="100"/></clipPath><rect id="shape" width="100" height="100" clip-path="url(#left)"/><clipPath id="right" clipPathUnits="objectBoundingBox"><rect x="0.5" width="0.5" height="1"/></clipPath><clipPath id="combined"><use xlink:href="#shape" clip-path="url(#right)"/></clipPath></defs><rect width="100" height="100" fill="red" clip-path="url(#combined)"/></svg>
                """
                let (skin, host) = try MediaUITests.bareSkin(t, """
                [Rainmeter]
                Update=-1
                [Drawing]
                Meter=SVG
                SVGImage=\(svg)
                W=100
                H=100
                """)
                defer { withExtendedLifetime(host) { skin.close() } }
                skin.update()
                guard let meter = skin.meter(named: "Drawing") as? SVGMeter else {
                    throw CocoaError(.coderInvalidValue)
                }
                let parsed = try Bitmap()
                SVGRenderer.draw(meter.lower(), in: parsed.canvas, context: DrawContext(fonts: AppFontResolver()))
                color(t, parsed, 35, 40, clear)
                color(t, parsed, 55, 40, leftWidth == 50 ? clear : red)
                color(t, parsed, 70, 40, clear)
            }
        }
    }

    private static func imageTests(_ t: AppTestRunner) {
        t.suite("Runtime: SVG drawing: embedded PNG orientation, alpha and paint order are preserved") {
            let data = try imageData()
            let item = SVGImageDraw(data: data, rect: SkinRect(x: 20, y: 10, width: 40, height: 40))
            let bitmap = try Bitmap()
            SVGRenderer.draw(snapshot([path(rect(0, 0, 100, 80), fill: .color(blue)), .image(item)]), in: bitmap.canvas,
                             context: DrawContext(fonts: AppFontResolver()))
            color(t, bitmap, 25, 15, red, tolerance: 2)
            color(t, bitmap, 55, 15, green, tolerance: 2)
            color(t, bitmap, 25, 45, blue, tolerance: 2)
            color(t, bitmap, 55, 45, blue, tolerance: 2)
            color(t, bitmap, 10, 10, blue)
        }

        t.suite("Runtime: SVG drawing: embedded image meet, slice, none and alignment use the image viewport") {
            let data = try imageData()
            let viewport = SkinRect(x: 20, y: 10, width: 80, height: 40)
            for (ratio, samples) in [
                (SVGPreserveAspectRatio(), [(25, 15, clear), (45, 15, red), (75, 15, green)]),
                (SVGPreserveAspectRatio(x: .max, y: .min), [(25, 15, clear), (65, 15, red), (95, 15, green)]),
                (SVGPreserveAspectRatio(x: .mid, y: .min, slice: true), [(25, 15, red), (95, 15, green)]),
                (SVGPreserveAspectRatio(none: true), [(25, 15, red), (95, 15, green), (25, 45, blue)])
            ] {
                let bitmap = try Bitmap()
                let image = SVGImageDraw(data: data, rect: viewport, preserveAspectRatio: ratio)
                SVGRenderer.draw(snapshot([.image(image)]), in: bitmap.canvas, context: DrawContext(fonts: AppFontResolver()))
                for (x, y, expected) in samples { color(t, bitmap, x, y, expected, tolerance: 3) }
                color(t, bitmap, 10, 15, clear)
                color(t, bitmap, 105, 15, clear)
                color(t, bitmap, 25, 55, clear)
            }
        }

        t.suite("Runtime: SVG drawing: embedded JPEG decodes while unsupported and malformed data stay empty") {
            let jpeg = try imageData(type: "public.jpeg")
            let bitmap = try Bitmap()
            let item = SVGImageDraw(data: jpeg, rect: SkinRect(x: 10, y: 10, width: 40, height: 40))
            let context = DrawContext(fonts: AppFontResolver())
            SVGRenderer.draw(snapshot([.image(item)]), in: bitmap.canvas, context: context)
            t.equal(context.svg.imageDecodes, 1)
            let repeated = snapshot([.image(SVGImageDraw(data: jpeg, rect: SkinRect(width: 20, height: 20))),
                                     .image(SVGImageDraw(data: jpeg, rect: SkinRect(x: 30, width: 20, height: 20)))])
            let reuse = DrawContext(fonts: AppFontResolver())
            SVGRenderer.draw(repeated, in: (try Bitmap()).canvas, context: reuse)
            t.equal(reuse.svg.imageDecodes, 1, "repeated use of one embedded image shares its decoded resource")
            t.check(bitmap.pixel(20, 20).a > 240)
            for invalid in [Data(), Data("https://example.invalid/image.png".utf8),
                            Data([137, 80, 78, 71, 13, 10, 26, 10]), Data("GIF89a".utf8)] {
                let empty = try Bitmap()
                SVGRenderer.draw(snapshot([.image(SVGImageDraw(data: invalid, rect: item.rect))]), in: empty.canvas,
                                 context: context)
                color(t, empty, 20, 20, clear)
            }
            t.equal(context.svg.imageDecodes, 1, "malformed or unsupported data cannot become an image resource")
        }
    }

    private static func cacheTests(_ t: AppTestRunner) {
        t.suite("Runtime: SVG drawing: distinct embedded images are bounded before decoding the next resource") {
            let context = DrawContext(fonts: AppFontResolver())
            var images: [SVGRenderNode] = []
            for index in 0..<17 {
                let data = try solidImageData(red: CGFloat(index + 1) / 20)
                images.append(.image(SVGImageDraw(data: data, rect: SkinRect(x: Double(index * 8), y: 20, width: 7, height: 7))))
            }
            let bitmap = try Bitmap()
            SVGRenderer.draw(snapshot(images), in: bitmap.canvas, context: context)
            t.equal(context.svg.imageDecodes, 16, "sixteen 4 MiB images consume the document's 64 MiB decode budget")
            t.check(bitmap.pixel(123, 23).a > 240)
            color(t, bitmap, 131, 23, clear, "the next distinct compressed image is rejected before allocation")
        }

        t.suite("Runtime: SVG drawing: owner cache reuses revisions and replays old snapshots independently") {
            let context = DrawContext(fonts: AppFontResolver())
            let identity = UUID(), data = try imageData()
            let old = snapshot([.image(SVGImageDraw(data: data, rect: SkinRect(x: 10, y: 10, width: 40, height: 40)))],
                               id: identity)
            let warm = try Bitmap(), cold = try Bitmap()
            SVGRenderer.draw(old, in: warm.canvas, context: context)
            SVGRenderer.draw(old, in: cold.canvas, context: context)
            t.equal(warm.bytes, cold.bytes)
            t.equal(context.svg.builds, 1)
            t.equal(context.svg.imageDecodes, 1)
            let new = snapshot([path(rect(10, 10, 40, 40), fill: .color(green))], id: identity, revision: 1)
            let changed = try Bitmap()
            SVGRenderer.draw(new, in: changed.canvas, context: context)
            color(t, changed, 20, 20, green)
            let replay = try Bitmap()
            SVGRenderer.draw(old, in: replay.canvas, context: context)
            t.equal(replay.bytes, warm.bytes, "the retained snapshot does not borrow resources from the live revision")
            t.equal(context.svg.count, 1)
            t.equal(context.svg.builds, 3)
            let separate = DrawContext(fonts: AppFontResolver())
            SVGRenderer.draw(old, in: (try Bitmap()).canvas, context: separate)
            t.equal(separate.svg.builds, 1)
            t.equal(context.svg.builds, 3)
            weak var released: DrawContext?
            do {
                let owner = DrawContext(fonts: AppFontResolver()); released = owner
                SVGRenderer.draw(old, in: (try Bitmap()).canvas, context: owner)
            }
            t.check(released == nil, "prepared resources do not retain their execution owner")
        }

        t.suite("Runtime: SVG drawing: cache source count is bounded and visual geometry retains strokes and transforms") {
            let context = DrawContext(fonts: AppFontResolver())
            for _ in 0..<(SVGRenderer.Cache.maxSources + 5) {
                _ = SVGRenderer.geometryBounds(snapshot([path(rect(0, 0, 10, 10), fill: .color(red))]), context: context)
            }
            t.equal(context.svg.count, SVGRenderer.Cache.maxSources)
            var style = ShapeStrokeStyle(); style.width = 10
            let item = SVGRenderNode.path(SVGPathDraw(path: rect(0, 0, 40, 20), fill: .none, stroke: .color(red), strokeStyle: style))
            let group = SVGRenderNode.group(transform: ShapeTransform(a: 2, b: 0, c: 0, d: 3, tx: 10, ty: 20),
                opacity: 1, clip: nil, children: [item])
            let draw = SVGDraw(contentFrame: SkinRect(x: 7, y: 9, width: 150, height: 100), nodes: [group])
            let bounds = SVGRenderer.geometryBounds(draw, context: context)
            t.close(bounds.minX, 7)
            t.close(bounds.minY, 14)
            t.close(bounds.maxX, 107)
            t.close(bounds.maxY, 104)
            let canvas = try Bitmap(); let before = canvas.canvas.ctm
            SVGRenderer.draw(draw, in: canvas.canvas, context: context)
            t.equal(canvas.canvas.ctm, before)
            canvas.canvas.setFillColor(green.cgColor)
            canvas.canvas.fill(CGRect(x: 130, y: 10, width: 10, height: 10))
            color(t, canvas, 135, 15, green, "drawing restores transforms and clipping")
        }
    }

    private static func snapshot(_ nodes: [SVGRenderNode], id: UUID = UUID(), revision: Int = 0) -> SVGDraw {
        SVGDraw(sourceID: id, revision: revision, contentFrame: SkinRect(width: 160, height: 100), nodes: nodes)
    }

    private static func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ShapePath {
        ShapePath(subpaths: [ShapeSubpath(start: ShapePoint(x, y), segments: [
            ShapeSegment(.line(to: ShapePoint(x + width, y))),
            ShapeSegment(.line(to: ShapePoint(x + width, y + height))),
            ShapeSegment(.line(to: ShapePoint(x, y + height)))
        ], closed: true)], fillRule: .nonZero)
    }

    private static func path(_ path: ShapePath, fill: SVGPaint) -> SVGRenderNode {
        .path(SVGPathDraw(path: path, fill: fill, stroke: .none, strokeStyle: ShapeStrokeStyle()))
    }

    private static func color(_ t: AppTestRunner, _ bitmap: Bitmap, _ x: Int, _ y: Int, _ expected: RGBA,
                              _ message: String = "", tolerance: Double = 1) {
        let actual = bitmap.pixel(x, y)
        t.check(abs(actual.r - expected.r) <= tolerance && abs(actual.g - expected.g) <= tolerance &&
                abs(actual.b - expected.b) <= tolerance && abs(actual.a - expected.a) <= tolerance,
                "pixel (\(x), \(y)) expected \(expected), got \(actual). \(message)")
    }

    private static func imageData(type: String = "public.png") throws -> Data {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 0, 0, 0, 0]
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.coderInvalidValue)
        }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, type as CFString, 1, nil) else {
            throw CocoaError(.coderInvalidValue)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.coderInvalidValue) }
        return result as Data
    }

    private static func solidImageData(red: CGFloat) throws -> Data {
        guard let canvas = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.coderInvalidValue)
        }
        canvas.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let result = NSMutableData()
        guard let image = canvas.makeImage(),
              let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.coderInvalidValue)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.coderInvalidValue) }
        return result as Data
    }

    private struct Bitmap {
        let canvas: CGContext
        let scale: Int
        let bgra: Bool
        init(scale: Int = 1, bgra: Bool = false) throws {
            self.scale = scale; self.bgra = bgra
            let info = bgra ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue :
                CGImageAlphaInfo.premultipliedLast.rawValue
            guard let canvas = CGContext(data: nil, width: 160 * scale, height: 100 * scale, bitsPerComponent: 8,
                bytesPerRow: 640 * scale, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else {
                throw CocoaError(.coderInvalidValue)
            }
            self.canvas = canvas
            canvas.clear(CGRect(x: 0, y: 0, width: 160 * scale, height: 100 * scale))
            canvas.translateBy(x: 0, y: CGFloat(100 * scale))
            canvas.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
            canvas.interpolationQuality = .none
        }
        var bytes: Data { Data(bytes: canvas.data!, count: canvas.bytesPerRow * canvas.height) }
        func pixel(_ x: Int, _ y: Int) -> RGBA {
            let p = canvas.data!.assumingMemoryBound(to: UInt8.self) + y * scale * canvas.bytesPerRow + x * scale * 4
            return RGBA(r: Double(p[bgra ? 2 : 0]), g: Double(p[1]), b: Double(p[bgra ? 0 : 2]), a: Double(p[3]))
        }
    }
}
