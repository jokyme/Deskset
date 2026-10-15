import AppKit
import CoreText
import DesksetCore
import DesksetDraw
import SwiftUI

enum IconDrawingSelfTests {
    private enum Failure: Error { case bitmap, preparation, timeout, fixture }

    static func run(_ t: AppTestRunner) {
        cacheTests(t)
        resourceTests(t)
        nativeTests(t)
    }

    private final class FontsFixture: FontResolving {
        var generation = 1
        func registerFolder(_ folder: String) {}
        func resolve(_ request: FontRequest) -> ResolvedFont {
            ResolvedFont(font: CTFontCreateWithName("Helvetica" as CFString, request.size, nil),
                         syntheticBold: false, characterMap: nil, slant: 0, lineMetrics: nil)
        }
    }

    private final class RasterFixture: IconRasterizing {
        var measured = 0
        var rendered = 0
        var available = true
        func isPrepared(_ request: IconRequest, font: ResolvedFont, fontGeneration: Int) -> Bool { available }
        func measure(_ request: IconRequest, font: ResolvedFont, fontGeneration: Int) throws -> SkinSize? {
            measured += 1
            guard available else { throw Failure.preparation }
            return request.name == "unknown" ? nil : SkinSize(width: 16, height: 12)
        }
        func rasterize(_ request: IconRequest, font: ResolvedFont, fontGeneration: Int, naturalSize: SkinSize,
                       pixelWidth: Int, pixelHeight: Int) throws -> RasterizedSymbol {
            rendered += 1
            let ctx = try IconDrawingSelfTests.bitmap(pixelWidth, pixelHeight)
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            guard let image = ctx.makeImage() else { throw Failure.bitmap }
            return RasterizedSymbol(image: image, pointSize: CGSize(width: naturalSize.width, height: naturalSize.height))
        }
    }

    private static func cacheTests(_ t: AppTestRunner) {
        t.suite("App: Desk icon native: complete requests and font generations isolate measurement and raster caches") {
            let fonts = FontsFixture(), provider = RasterFixture()
            let cache = IconCache(fonts: fonts, rasterizer: provider)
            let base = request("wifi")
            t.equal(try cache.measure(base), SkinSize(width: 16, height: 12))
            _ = try cache.measure(base)
            t.equal(provider.measured, 1, "repeated measurement reuses the native result")
            var changes = [IconRequest]()
            var changed = base; changed.style.fontFace = "Times-Roman"; changes.append(changed)
            changed = base; changed.style.italic = true; changes.append(changed)
            changed = base; changed.style.color = .white; changes.append(changed)
            changed = base; changed.colors = .multicolor; changes.append(changed)
            changed = base; changed.scale = 2; changes.append(changed)
            var appearance = base.appearance.value; appearance.accentColor = RGBA(r: 180, g: 20, b: 40)
            changed = base; changed.appearance = AppearanceStamp(value: appearance, name: base.appearance.name); changes.append(changed)
            for value in changes { _ = try cache.measure(value) }
            t.equal(provider.measured, 1 + changes.count, "full font, color, appearance and display scale remain distinct")
            fonts.generation += 1
            _ = try cache.measure(base)
            t.equal(provider.measured, 2 + changes.count)
            var unknown = base; unknown.name = "unknown"
            t.check(try cache.measure(unknown) == nil)
            _ = try cache.measure(unknown)
            t.equal(provider.measured, 3 + changes.count, "unknown is a cached empty value")
            provider.available = false
            do { _ = try cache.measure(base); t.check(false, "cached metrics cannot conceal an evicted native resource") }
            catch Failure.preparation { t.check(true) }
            provider.available = true
            let drawing = IconDraw(request: base, naturalSize: SkinSize(width: 16, height: 12),
                                   contentFrame: SkinRect(x: 4, y: 3, width: 32, height: 24))
            let ctx = try bitmap(160, 160)
            ctx.scaleBy(x: 2, y: -2); ctx.rotate(by: .pi / 2)
            guard let image = try cache.prepare(drawing, in: ctx) else { throw Failure.fixture }
            t.equal(image.width, 64); t.equal(image.height, 48)
            let builds = provider.rendered
            ctx.translateBy(x: 0.375, y: 0.625)
            _ = try cache.prepare(drawing, in: ctx)
            t.equal(provider.rendered, builds, "phase changes do not demand a different density")
            ctx.scaleBy(x: 2, y: 0.5)
            guard let stretched = try cache.prepare(drawing, in: ctx) else { throw Failure.fixture }
            t.equal(stretched.width, 128); t.equal(stretched.height, 96, "nonuniform transforms retain sufficient density")
        }

        t.suite("App: Desk icon native: preflight pins bound bitmap storage and reject impossible allocations") {
            let fonts = FontsFixture(), provider = RasterFixture()
            let cache = IconCache(fonts: fonts, rasterizer: provider, maximumBitmapBytes: 3_072)
            let ctx = try bitmap(64, 64)
            func drawing(_ name: String) -> IconDraw {
                IconDraw(request: request(name), naturalSize: SkinSize(width: 16, height: 12),
                         contentFrame: SkinRect(width: 16, height: 12))
            }
            cache.beginFrame()
            for name in ["a", "b", "c", "d"] { _ = try cache.prepare(drawing(name), in: ctx, pin: true) }
            t.equal(cache.bitmapBytes, 3_072)
            do { _ = try cache.prepare(drawing("e"), in: ctx, pin: true); t.check(false) }
            catch IconDrawingError.bitmapBudget { t.check(true) }
            t.equal(provider.rendered, 4, "budget rejection precedes the native allocation")
            let retained = provider.rendered
            _ = try cache.prepare(drawing("a"), in: ctx)
            t.equal(provider.rendered, retained, "earlier accepted images cannot be evicted during the frame")
            cache.cancelFrame()
            _ = try cache.prepare(drawing("e"), in: ctx)
            t.equal(provider.rendered, retained + 1)
            t.check(cache.bitmapBytes <= 3_072)
            var enormous = drawing("a"); enormous.contentFrame.width = Double.greatestFiniteMagnitude
            let before = provider.rendered
            do { _ = try cache.prepare(enormous, in: ctx); t.check(false) }
            catch IconDrawingError.bitmapBudget { t.check(true) }
            t.equal(provider.rendered, before)
        }
    }

    private static func resourceTests(_ t: AppTestRunner) {
        t.suite("App: Desk icon native: asynchronous immutable resources keep unknown cancellation and font identity distinct") {
            let resources = DeskIconResources()
            let known = demand(request("person.crop.circle.fill"))
            var missingRequest = known.request; missingRequest.name = "deskset.no.such.symbol"
            let missing = demand(missingRequest)
            resources.beginProjection()
            if case .missing = resources.lookup(known) { t.check(true) } else { t.check(false) }
            _ = resources.lookup(missing)
            let batch = try prepare([known, missing])
            try resources.install(batch)
            if case .ready(let image) = resources.lookup(known) {
                t.check(image.size.width > 0 && image.size.height > 0 && !image.pdf.isEmpty)
            } else { t.check(false) }
            if case .unknown = resources.lookup(missing) { t.check(true) } else { t.check(false) }
            resources.commitProjection(); resources.beginProjection()
            let newGeneration = DeskIconResources.Demand(request: known.request, font: known.font,
                                                        fontGeneration: known.fontGeneration + 1)
            t.check(newGeneration != known)
            if case .missing = resources.lookup(newGeneration) { t.check(true) } else { t.check(false) }
            let otherFont = ResolvedFont(font: CTFontCreateWithName("Times-Roman" as CFString, 32, nil),
                                        syntheticBold: false, characterMap: nil, slant: 0, lineMetrics: nil)
            let other = DeskIconResources.Demand(request: known.request, font: otherFont, fontGeneration: known.fontGeneration)
            t.check(other != known, "a resolved font identity cannot alias a same-request source")
            let before = resources.count
            do {
                try resources.install(.init(entries: [.init(demand: other,
                    prepared: .init(size: SkinSize(width: 10, height: 10), pdf: Data([1, 2, 3])))]))
                t.check(false)
            } catch DeskIconResources.Failure.invalidResource { t.check(true) }
            t.equal(resources.count, before, "invalid batches leave committed resources intact")
            resources.cancelProjection()
            if case .ready = resources.lookup(known) { t.check(true) } else { t.check(false) }
            var delivered = false
            let ticket = DeskIconResources.prepare([other]) { _ in delivered = true }
            ticket.cancel(); ticket.cancel()
            let until = Date().addingTimeInterval(0.04)
            while Date() < until { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
            t.check(ticket.isCancelled && !delivered, "cancelled Main work never calls its owner completion")
        }

        t.suite("App: Desk icon native: committed PDF sources survive candidate cleanup and historical eviction") {
            let resources = DeskIconResources(), original = demand(request("wifi"))
            resources.beginProjection(); _ = resources.lookup(original)
            try resources.install(try prepare([original])); resources.commitProjection()
            resources.beginProjection()
            var entries = [DeskIconResources.Entry]()
            for index in 0..<1_040 {
                var value = original.request; value.name = "missing-\(index)"
                entries.append(.init(demand: demand(value), prepared: nil))
            }
            try resources.install(.init(entries: entries))
            t.check(resources.count <= 1_024)
            if case .ready = resources.lookup(original) { t.check(true) } else { t.check(false, "committed source is protected") }
            resources.cancelProjection()
            t.check(resources.pdfBytes > 0 && resources.pdfBytes <= DeskIconResources.maximumPDFBytes)
            var otherRequest = original.request; otherRequest.name = "image-fallback"
            for (kind, rasterPDF) in [("XObject", try pdfWithImage()), ("inline", pdfWithInlineImage())] {
                do {
                    try resources.install(.init(entries: [.init(demand: demand(otherRequest),
                        prepared: .init(size: SkinSize(width: 4, height: 4), pdf: rasterPDF))]))
                    t.check(false, "a fixed-density \(kind) image inside the native document is not vector preparation")
                } catch DeskIconResources.Failure.unsupportedRasterContent { t.check(true) }
            }
            for (kind, bounds) in [
                ("nonzero origin", CGRect(x: 0.001, y: 0, width: 4, height: 4)),
                ("different width", CGRect(x: 0, y: 0, width: 4.001, height: 4)),
                ("different height", CGRect(x: 0, y: 0, width: 4, height: 4.001)),
            ] {
                let pdf = try pdfWithPage(bounds)
                do {
                    try resources.install(.init(entries: [.init(demand: demand(otherRequest),
                        prepared: .init(size: SkinSize(width: 4, height: 4), pdf: pdf))]))
                    t.check(false, "\(kind) exceeds PDF coordinate serialization rounding")
                } catch DeskIconResources.Failure.invalidMediaBox { t.check(true) }
            }
        }
    }

    private static func nativeTests(_ t: AppTestRunner) {
        t.suite("App: Desk icon native: literal SwiftUI reference preserves native color layers at both display scales") {
            for dark in [false, true] {
                for scale in [1.0, 2.0] {
                    for colors in IconColors.allCases {
                        for symbol in ["person.crop.circle.fill", "cloud.sun.fill"] {
                            let input = request(symbol, colors: colors, scale: scale, dark: dark,
                                                color: RGBA(r: 13, g: 64, b: 204, a: 102))
                            let resources = DeskIconResources()
                            resources.beginProjection(); _ = resources.lookup(demand(input))
                            try resources.install(try prepare([demand(input)]))
                            let context = DrawContext(fonts: AppFontResolver(), icons: AppIconRasterizer(resources: resources))
                            guard let size = try context.icons.measure(input) else { throw Failure.fixture }
                            let expected = try reference(input, points: 32, weight: .regular)
                            let actual = try draw(input, size: size, context: context)
                            t.equal(actual.width, expected.width); t.equal(actual.height, expected.height)
                            let a = try pixels(actual), b = try pixels(expected)
                            guard a.count == b.count else { continue }
                            let alpha = stride(from: 3, to: b.count, by: 4).reduce(0) { $0 + Int(b[$1]) }
                            let delta = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                            t.check(alpha > 0)
                            // Independent vector/PDF and SwiftUI rasterizers differ at antialiased edges. A global
                            // recolor, omitted fixed layer, wrong alpha or vertical flip is far outside this bound.
                            t.check(Double(delta) / Double(max(alpha * 4, 1)) < 0.04,
                                    "\(symbol) \(colors) \(scale)x dark=\(dark): normalized difference \(Double(delta) / Double(max(alpha * 4, 1)))")
                        }
                    }
                }
            }
        }

        t.suite("App: Desk icon native: font units weight and large vector replay remain native") {
            let resources = DeskIconResources()
            let normal = request("wifi", scale: 2), bold = request("wifi", scale: 2, weight: 900)
            let large = request("wifi", scale: 2, points: 128)
            resources.beginProjection()
            for input in [normal, bold, large] { _ = resources.lookup(demand(input)) }
            try resources.install(try prepare([normal, bold, large].map(demand)))
            let context = DrawContext(fonts: AppFontResolver(), icons: AppIconRasterizer(resources: resources))
            var images = [CGImage]()
            for input in [normal, bold, large] {
                guard let size = try context.icons.measure(input) else { throw Failure.fixture }
                let image = try draw(input, size: size, context: context)
                let points = input.style.fontSize * 96 / 72
                let expected = try reference(input, points: points, weight: input.style.fontWeight == 900 ? .black : .regular)
                t.equal(image.width, expected.width); t.equal(image.height, expected.height)
                images.append(image)
            }
            t.check(try pixels(images[0]) != pixels(images[1]), "weight changes the native symbol")
            t.check(images[2].width > images[0].width * 3 && images[2].height > images[0].height * 3,
                    "128pt stays a native vector source, without doubling the 96/72 conversion")
        }

        t.suite("App: Desk icon native: fractional scales and battery symbols preserve native metrics and coverage") {
            for scale in [1.25, 3.0] {
                for symbol in ["laptopcomputer", "bolt.fill", "powerplug.fill", "desktopcomputer", "cloud.sun.fill"] {
                    let input = request(symbol, colors: .multicolor, scale: scale, points: 17.3)
                    let resources = DeskIconResources()
                    resources.beginProjection(); _ = resources.lookup(demand(input))
                    do { try resources.install(try prepare([demand(input)])) }
                    catch { t.check(false, "\(symbol) \(scale)x 17.3pt resource: \(error)"); continue }
                    let context = DrawContext(fonts: AppFontResolver(), icons: AppIconRasterizer(resources: resources))
                    guard let size = try context.icons.measure(input) else { throw Failure.fixture }
                    let actual = try draw(input, size: size, context: context)
                    let expected = try reference(input, points: 17.3, weight: .regular)
                    t.equal(actual.width, expected.width, "\(symbol) \(scale)x width")
                    t.equal(actual.height, expected.height, "\(symbol) \(scale)x height")
                    let a = try pixels(actual), b = try pixels(expected)
                    guard a.count == b.count else { continue }
                    let alpha = stride(from: 3, to: b.count, by: 4).reduce(0) { $0 + Int(b[$1]) }
                    let delta = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                    t.check(alpha > 0)
                    t.check(Double(delta) / Double(max(alpha * 4, 1)) < 0.06,
                            "\(symbol) \(scale)x fractional native difference \(Double(delta) / Double(max(alpha * 4, 1)))")
                }
            }
        }

        t.suite("App: Desk icon native: simulated font traits use native modifiers without distorting symbols") {
            let input = request("wifi", scale: 2, weight: 700)
            let upright = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
            let font = ResolvedFont(font: upright, syntheticBold: true, characterMap: nil, slant: 0.2, lineMetrics: nil)
            let value = DeskIconResources.Demand(request: input, font: font, fontGeneration: 0)
            let resources = DeskIconResources()
            resources.beginProjection(); _ = resources.lookup(value)
            try resources.install(try prepare([value]))
            let rasterizer = AppIconRasterizer(resources: resources)
            guard let size = try rasterizer.measure(input, font: font, fontGeneration: 0) else { throw Failure.fixture }
            let actual = try rasterizer.rasterize(input, font: font, fontGeneration: 0, naturalSize: size,
                                                 pixelWidth: Int(ceil(size.width * 2)), pixelHeight: Int(ceil(size.height * 2))).image
            let expected = try MainActor.assumeIsolated {
                try nativeReference(input, font: SwiftUI.Font.custom("Helvetica", size: 32).bold().italic())
            }
            let regular = try MainActor.assumeIsolated {
                try nativeReference(input, font: SwiftUI.Font.custom("Helvetica", size: 32))
            }
            t.equal(actual.width, expected.width); t.equal(actual.height, expected.height)
            let a = try pixels(actual), b = try pixels(expected)
            if a.count == b.count {
                let alpha = stride(from: 3, to: b.count, by: 4).reduce(0) { $0 + Int(b[$1]) }
                let delta = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                t.check(Double(delta) / Double(max(alpha * 4, 1)) < 0.04)
            }
            t.check(try pixels(expected) != pixels(regular), "synthetic bold cannot disappear at the PDF boundary")
        }
    }

    private static func request(_ name: String, colors: IconColors = .monochrome, scale: Double = 1,
                                dark: Bool = false, color: RGBA = RGBA(r: 20, g: 100, b: 230),
                                points: Double = 32, weight: Int = 400) -> IconRequest {
        var style = TextStyle(); style.fontFace = "System"; style.fontSize = points * 72 / 96
        style.fontWeight = weight; style.color = color
        return IconRequest(name: name, style: style, colors: colors,
                           appearance: AppearanceStamp(value: dark ? .dark : .light,
                                                       name: (dark ? NSAppearance.Name.darkAqua : .aqua).rawValue), scale: scale)
    }

    private static func demand(_ request: IconRequest) -> DeskIconResources.Demand {
        let fonts = AppFontResolver()
        return .init(request: request, font: fonts.resolve(FontRequest(style: request.style)), fontGeneration: fonts.generation)
    }

    private static func prepare(_ demands: [DeskIconResources.Demand]) throws -> DeskIconResources.Batch {
        precondition(Thread.isMainThread)
        var result: Result<DeskIconResources.Batch, Error>?
        let ticket = DeskIconResources.prepare(demands) { result = $0 }
        let limit = Date().addingTimeInterval(5)
        while result == nil && Date() < limit {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard let result else { ticket.cancel(); throw Failure.timeout }
        return try result.get()
    }

    @MainActor
    private static func nativeReference(_ input: IconRequest, points: Double, weight: SwiftUI.Font.Weight) throws -> CGImage {
        try nativeReference(input, font: .system(size: points, weight: weight))
    }

    @MainActor
    private static func nativeReference(_ input: IconRequest, font: SwiftUI.Font) throws -> CGImage {
        let mode: SymbolRenderingMode = input.colors == .monochrome ? .monochrome
            : input.colors == .hierarchical ? .hierarchical : .multicolor
        let c = input.style.color
        let content = SwiftUI.Image(systemName: input.name).font(font)
            .symbolRenderingMode(mode)
            .foregroundStyle(Color(.sRGB, red: c.r / 255, green: c.g / 255, blue: c.b / 255, opacity: c.a / 255))
            .environment(\.colorScheme, input.appearance.value.isDark ? .dark : .light)
            .environment(\.displayScale, input.scale).fixedSize()
        let renderer = SwiftUI.ImageRenderer(content: content); renderer.scale = input.scale; renderer.colorMode = .nonLinear
        _ = renderer.cgImage
        guard let image = renderer.cgImage else { throw Failure.bitmap }
        return image
    }

    private static func reference(_ input: IconRequest, points: Double, weight: SwiftUI.Font.Weight) throws -> CGImage {
        try MainActor.assumeIsolated { try nativeReference(input, points: points, weight: weight) }
    }

    private static func draw(_ request: IconRequest, size: SkinSize, context: DrawContext) throws -> CGImage {
        let ctx = try bitmap(Int(ceil(size.width * request.scale)), Int(ceil(size.height * request.scale)))
        ctx.translateBy(x: 0, y: CGFloat(ctx.height)); ctx.scaleBy(x: request.scale, y: -request.scale)
        let icon = IconDraw(request: request, naturalSize: size, contentFrame: SkinRect(width: size.width, height: size.height))
        context.icons.beginFrame(); _ = try context.icons.prepare(icon, in: ctx, pin: true)
        DesksetDraw.DrawExecutor.draw([.icon(icon)], in: ctx, context: context, cycle: 1,
                                     target: DrawTarget.capture(ctx, glass: .none))
        guard let image = ctx.makeImage() else { throw Failure.bitmap }; return image
    }

    private static func bitmap(_ width: Int, _ height: Int) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                       | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.bitmap }
        return result
    }

    private static func pixels(_ image: CGImage) throws -> Data {
        let ctx = try bitmap(image.width, image.height)
        ctx.setBlendMode(.copy); ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = ctx.data else { throw Failure.bitmap }
        return Data(bytes: bytes, count: ctx.bytesPerRow * ctx.height)
    }

    private static func pdfWithImage() throws -> Data {
        let imageContext = try bitmap(2, 2)
        imageContext.setFillColor(CGColor(gray: 1, alpha: 1)); imageContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = imageContext.makeImage() else { throw Failure.bitmap }
        let data = NSMutableData(); var bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw Failure.bitmap }
        context.beginPDFPage(nil); context.draw(image, in: bounds); context.endPDFPage(); context.closePDF()
        return data as Data
    }

    private static func pdfWithPage(_ page: CGRect) throws -> Data {
        let data = NSMutableData(); var bounds = page
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw Failure.bitmap }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(bounds)
        context.endPDFPage(); context.closePDF()
        return data as Data
    }

    private static func pdfWithInlineImage() -> Data {
        let stream = "q 4 0 0 4 0 0 cm BI /W 1 /H 1 /CS /RGB /BPC 8 /F /AHx ID FF0000> EI Q\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 4 4] /Resources << >> /Contents 4 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
        ]
        var result = Data("%PDF-1.4\n".utf8), offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 5\n0000000000 65535 f \n".utf8))
        for offset in offsets { result.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        result.append(Data("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }
}
