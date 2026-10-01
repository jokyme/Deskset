import AppKit
import ImageIO
import DesksetCore
import DesksetDraw

enum DrawImageSelfTests {
    private static let mappings: [(name: String, transform: CGAffineTransform, horizontal: CGFloat,
                                   maximum: CGFloat, decodeSide: Int)] = [
        ("1x", .identity, 1, 1, 128),
        ("2x", CGAffineTransform(scaleX: 2, y: 2), 2, 2, 256),
        ("nonuniform", CGAffineTransform(scaleX: 1, y: 3), 1, 3, 320),
        ("quarter turn", CGAffineTransform(a: 0, b: 1, c: -3, d: 0, tx: 0, ty: 0), 1, 3, 320),
        ("reflection", CGAffineTransform(scaleX: -2, y: 3), 2, 3, 320),
        ("large", CGAffineTransform(a: 3, b: 4, c: 5, d: 12, tx: 0, ty: 0), 5, 13, 448),
        ("small", CGAffineTransform(scaleX: 0.5, y: 0.5), 0.5, 0.5, 128),
        ("zero", CGAffineTransform(scaleX: 0, y: 0), 0, 0, 128),
    ]

    private static let nonfinite = [
        CGAffineTransform(a: .nan, b: 0, c: .nan, d: 0, tx: 0, ty: 0),
        CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0),
    ]

    static func run(_ t: AppTestRunner) {
        t.suite("App: draw image boundary: target keeps the current basis vectors") {
            for mapping in mappings {
                let target = DrawTarget(userToDevice: mapping.transform)
                t.equal(target.userToDevice, mapping.transform, mapping.name)
                t.close(target.horizontalPixelsPerPoint, mapping.horizontal, mapping.name)
                t.close(target.maximumPixelsPerPoint, mapping.maximum, mapping.name)
            }
            let translated = DrawTarget(userToDevice: CGAffineTransform(a: 2, b: 0, c: 0, d: 3,
                                                                         tx: .nan, ty: .infinity))
            t.close(translated.horizontalPixelsPerPoint, 2, "translation does not set density")
            t.close(translated.maximumPixelsPerPoint, 3)
            for transform in nonfinite {
                let target = DrawTarget(userToDevice: transform)
                t.check(!target.horizontalPixelsPerPoint.isFinite)
                t.check(!target.maximumPixelsPerPoint.isFinite, "callers keep their own fallback")
            }
            let densityOnly = DrawTarget(userToDevice: .identity)
            t.check(densityOnly.colorSpace == nil && densityOnly.state == nil,
                    "a mapping alone supplies no destination space or graphics state")
        }

        t.suite("App: draw image boundary: captured destinations keep their space and inherited state") {
            for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
                guard let space = CGColorSpace(name: name),
                      let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return t.check(false, "destination context")
                }
                ctx.translateBy(x: 3.25, y: 47.5)
                ctx.scaleBy(x: 1.5, y: -2)
                ctx.clip(to: CGRect(x: 2, y: 4, width: 10, height: 8))
                ctx.interpolationQuality = .none
                let position = CGPoint(x: 4.5, y: 6.25)
                // CoreGraphics' text position shares the text matrix's translation.
                let matrix = CGAffineTransform(a: 1, b: 0, c: 0.25, d: -1, tx: position.x, ty: position.y)
                ctx.textMatrix = matrix
                ctx.textPosition = position
                let mapping = ctx.userSpaceToDeviceSpaceTransform, ctm = ctx.ctm, clip = ctx.boundingBoxOfClipPath
                for glass in [GlassPaint.none, .hitArea, .placeholder(dark: nil), .placeholder(dark: false),
                              .placeholder(dark: true)] {
                    let target = DrawTarget.capture(ctx, glass: glass)
                    t.check(target.colorSpace == space, "the destination keeps its actual profile, \(name)")
                    t.equal(target.glassPaint, glass)
                    t.equal(target.userToDevice, mapping)
                    t.equal(target.ctm, ctm)
                    t.equal(target.state?.interpolationQuality, CGInterpolationQuality.none)
                    t.equal(target.state?.textMatrix, matrix)
                    t.equal(target.state?.textPosition, position)
                    t.equal(ctx.ctm, ctm, "capture adds no flip or alignment")
                    t.equal(ctx.boundingBoxOfClipPath, clip, "capture keeps the inherited clip")
                    ctx.interpolationQuality = .high
                    ctx.textMatrix = .identity
                    ctx.textPosition = .zero
                    t.equal(target.state?.interpolationQuality, CGInterpolationQuality.none,
                            "later context changes do not change captured state")
                    t.equal(target.state?.textMatrix, matrix)
                    t.equal(target.state?.textPosition, position)
                    ctx.interpolationQuality = .none
                    ctx.textMatrix = matrix
                    ctx.textPosition = position
                }
            }
        }

        t.suite("App: draw image boundary: symbols use the largest scale") {
            let symbol = MacSymbol(name: "cpu.fill")
            let options = ImageOptions()
            for mapping in mappings {
                let target = DrawTarget(userToDevice: mapping.transform)
                let path = SymbolImages.drawingPath(symbol.path, options: options, drawn: nil, target: target)
                t.close(MacSymbol(path: path)?.density ?? 0, Double(mapping.maximum > 0 ? mapping.maximum : 1),
                        mapping.name)
                guard let ctx = Images.bitmapContext(width: 32, height: 32) else {
                    return t.check(false, "context")
                }
                // A singular CGContext transform is not a drawable mapping; its fallback is tested as a value.
                if mapping.maximum == 0 { continue }
                ctx.concatenate(mapping.transform)
                t.equal(SymbolImages.drawingPath(symbol.path, options: options, drawn: nil, in: ctx), path,
                        "the context adapter uses the same mapping: \(mapping.name)")
                #if DEBUG
                t.equal(LegacySymbolImages.drawingPath(symbol.path, options: options, drawn: nil, in: ctx), path,
                        "the frozen renderer chooses the same cache key")
                #endif
            }
            for transform in nonfinite {
                let path = SymbolImages.drawingPath(symbol.path, options: options, drawn: nil,
                                                    target: DrawTarget(userToDevice: transform))
                t.equal(path, symbol.path, "a nonfinite device scale falls back to 1x")
            }
            guard let size = Images.size(atPath: symbol.path) else { return t.check(false, "symbol renders") }
            let rounded = SymbolImages.drawingPath(symbol.path, options: options,
                                                    drawn: CGSize(width: size.width * 1.01, height: size.height * 1.01),
                                                    target: DrawTarget(userToDevice: .identity))
            t.close(MacSymbol(path: rounded)?.density ?? 0, 1.125, "density rounds up in eighths")
            t.equal(SymbolImages.drawingPath("/tmp/plain.png", options: options, drawn: nil,
                                             target: DrawTarget(userToDevice: .identity)), "/tmp/plain.png")
        }

        symbolPixels(t)
        decodePaths(t)
        #if DEBUG
        maskedPixels(t)
        #endif
    }

    private static func symbolPixels(_ t: AppTestRunner) {
        t.suite("App: draw image boundary: symbol protocol preserves pixels and point sizes") {
            let rasterizer: any SymbolRasterizing = AppSymbolRasterizer()
            for rendering in MacSymbol.Rendering.allCases {
                let style = MacSymbol.Style(pointSize: 23, weight: .semibold, rendering: rendering,
                                            colors: [.white, RGBA(r: 255, g: 160, b: 0, a: 153)])
                for density in [1.0, 2.0] {
                    let symbol = MacSymbol(name: "cloud.sun.fill", style: style, density: density)
                    guard let result = rasterizer.render(symbol), let original = SymbolImages.render(symbol),
                          let cached = Images.entry(atPath: symbol.path) else {
                        return t.check(false, "\(rendering) at \(density)x renders")
                    }
                    t.equal(result.pointSize, original.pointSize)
                    t.close(cached.pointSize.width, Double(result.pointSize.width))
                    t.close(cached.pointSize.height, Double(result.pointSize.height))
                    t.check(cached.image === Images.entry(atPath: symbol.path)?.image, "the cache reuses one render")
                    t.check(result.image.colorSpace?.name == CGColorSpace.sRGB, "the raster stays in sRGB")
                    #if DEBUG
                    t.check(LegacyRenderSelfTests.bytesEqual(result.image, original.image))
                    t.check(LegacyRenderSelfTests.bytesEqual(result.image, cached.image), "cached pixels match the rasterizer")
                    guard let legacy = LegacySymbolImages.render(symbol) else {
                        return t.check(false, "the frozen symbol rasterizer renders")
                    }
                    t.equal(result.pointSize, legacy.pointSize)
                    t.check(LegacyRenderSelfTests.bytesEqual(result.image, legacy.image), "unchanged platform pixels")
                    #endif
                }
            }
            for name in ["", "no.such.symbol.here"] {
                let symbol = MacSymbol(name: name)
                t.check(rasterizer.render(symbol) == nil)
                t.check(Images.entry(atPath: symbol.path) == nil, "failed symbols keep returning nil")
            }
        }
    }

    private static func decodePaths(_ t: AppTestRunner) {
        t.suite("App: draw image boundary: drawn decoding keeps scale clamps and size buckets") {
            let file = t.temporaryDirectory("draw-image-decode").appendingPathComponent("Photo.png")
            guard let photo = Images.bitmapContext(width: 1024, height: 512) else {
                return t.check(false, "photo context")
            }
            photo.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            photo.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
            guard let image = photo.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)
            else { return t.check(false, "photo") }
            CGImageDestinationAddImage(dest, image, nil)
            t.check(CGImageDestinationFinalize(dest), "photo written")
            let options = ImageOptions(), drawn = CGSize(width: 100, height: 50)
            for mapping in mappings {
                let path = SkinRenderer.drawnDecodePath(file.path, options: options, drawn: drawn, fit: false,
                                                        target: DrawTarget(userToDevice: mapping.transform))
                t.equal(Images.decodeRequest(path)?.side, mapping.decodeSide, mapping.name)
                t.equal(Images.decodeRequest(path)?.file, file.path)
                t.equal(Images.cgImage(atPath: path).map { [$0.width, $0.height] },
                        [mapping.decodeSide, mapping.decodeSide / 2], "the chosen cache key decodes at that size")
                guard mapping.maximum > 0 else { continue }
                guard let ctx = Images.bitmapContext(width: 32, height: 32) else {
                    return t.check(false, "context")
                }
                ctx.concatenate(mapping.transform)
                t.equal(SkinRenderer.drawnDecodePath(file.path, options: options, drawn: drawn, fit: false, in: ctx),
                        path, "context adapter: \(mapping.name)")
                #if DEBUG
                t.equal(LegacySkinRenderer.drawnDecodePath(file.path, options: options, drawn: drawn, fit: false,
                                                          in: ctx), path, "unchanged decode cache key")
                #endif
            }
            for transform in nonfinite {
                let path = SkinRenderer.drawnDecodePath(file.path, options: options, drawn: drawn, fit: false,
                                                        target: DrawTarget(userToDevice: transform))
                t.equal(Images.decodeRequest(path)?.side, 128, "a nonfinite scale falls back to 1x")
            }
            let target = DrawTarget(userToDevice: .identity)
            t.equal(SkinRenderer.drawnDecodePath(file.path, options: options, drawn: CGSize(width: CGFloat.nan, height: 50),
                                                 fit: false, target: target), file.path, "invalid dimensions pass through")
            let symbol = MacSymbol(name: "cpu.fill").path
            t.equal(SkinRenderer.drawnDecodePath(symbol, options: options, drawn: drawn, fit: false, target: target),
                    symbol, "symbols are not file decodes")
        }
    }

    #if DEBUG
    private static func maskedPixels(_ t: AppTestRunner) {
        t.suite("App: draw image boundary: masks keep the horizontal scale and legacy pixels") {
            guard let fixtures = Paths.repositoryFolder("TestSkins/Image/ImageMeters/@Resources/Images") else {
                return t.check(false, "image fixtures")
            }
            let path = fixtures.appendingPathComponent("Card.png").path
            let options = ImageOptions()
            guard let prepared = PreparedImage(path: path, options: options),
                  let legacy = LegacyPreparedImage(path: path, options: options) else {
                return t.check(false, "card fixture")
            }
            let area = CGRect(x: -20, y: -15, width: 40, height: 30)
            func context(_ transform: CGAffineTransform) -> CGContext? {
                guard let ctx = Images.bitmapContext(width: 256, height: 256) else { return nil }
                ctx.translateBy(x: 128, y: 128)
                ctx.concatenate(transform)
                return ctx
            }
            let transforms = mappings.prefix(5).map(\.transform)
                + [CGAffineTransform(scaleX: 1.005, y: 3), CGAffineTransform(scaleX: 1.015, y: 3)]
            let masks = [fixtures.appendingPathComponent("Mask.png").path, MacSymbol(name: "circle.fill").path]
            for mask in masks {
                for transform in transforms {
                    guard let current = context(transform), let value = context(transform),
                          let reference = context(transform) else { return t.check(false, "mask contexts") }
                    SkinRenderer.drawMasked(prepared, maskPath: mask, maskOptions: options, in: area, current)
                    SkinRenderer.drawMasked(prepared, maskPath: mask, maskOptions: options, in: area, value,
                                            target: DrawTarget(userToDevice: value.userSpaceToDeviceSpaceTransform))
                    LegacySkinRenderer.drawMasked(legacy, maskPath: mask, maskOptions: options, in: area, reference)
                    guard let a = current.makeImage(), let b = reference.makeImage(), let c = value.makeImage() else {
                        return t.check(false, "masked images")
                    }
                    t.check(!LegacyRenderSelfTests.isEmpty(a), "the fixture draws visible pixels")
                    t.check(LegacyRenderSelfTests.bytesEqual(a, b), "unchanged mask pixels at \(transform)")
                    t.check(LegacyRenderSelfTests.bytesEqual(a, c), "the target and context adapters agree")
                }
            }
            // This fixture must distinguish the two density rules, or a nonuniform-scale regression could pass.
            let nonuniform = CGAffineTransform(scaleX: 1, y: 3)
            guard let horizontal = context(nonuniform), let maximum = context(nonuniform) else {
                return t.check(false, "density canary contexts")
            }
            SkinRenderer.drawMasked(prepared, maskPath: masks[0], maskOptions: options, in: area, horizontal)
            SkinRenderer.drawMasked(prepared, maskPath: masks[0], maskOptions: options, in: area, maximum,
                                    target: DrawTarget(userToDevice: CGAffineTransform(scaleX: 3, y: 3)))
            guard let xPixels = horizontal.makeImage(), let maxPixels = maximum.makeImage() else {
                return t.check(false, "density canary images")
            }
            t.check(!LegacyRenderSelfTests.bytesEqual(xPixels, maxPixels), "using the larger scale changes mask pixels")
            // A valid drawing context and a nonfinite scale value exercise the existing 1x fallback safely.
            for transform in nonfinite {
                guard let fallback = context(.identity), let reference = context(.identity) else {
                    return t.check(false, "fallback contexts")
                }
                SkinRenderer.drawMasked(prepared, maskPath: masks[0], maskOptions: options, in: area, fallback,
                                        target: DrawTarget(userToDevice: transform))
                LegacySkinRenderer.drawMasked(legacy, maskPath: masks[0], maskOptions: options, in: area, reference)
                guard let a = fallback.makeImage(), let b = reference.makeImage() else {
                    return t.check(false, "fallback images")
                }
                t.check(LegacyRenderSelfTests.bytesEqual(a, b), "nonfinite mask density still falls back to 1x")
            }
        }
    }
    #endif
}
