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
                    t.check(target.state?.rasterization == nil && target.state?.blendMode == nil,
                            "capturing a borrowed context does not infer unreadable state")
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

        ownedState(t)

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
        ownedPixels(t)
        #endif
    }

    private static func ownedState(_ t: AppTestRunner) {
        t.suite("App: draw image boundary: owned bitmaps establish scene state without changing destination facts") {
            for (name, space) in try bitmapSpaces() {
                guard let ctx = CGContext(data: nil, width: 72, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return t.check(false, "owned destination: \(name)")
                }
                ctx.translateBy(x: 3.25, y: 59.5)
                ctx.scaleBy(x: 1.5, y: -2)
                ctx.clip(to: CGRect(x: 2.5, y: 4.25, width: 18.5, height: 12.25))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                defer { NSGraphicsContext.restoreGraphicsState() }
                let ctm = ctx.ctm, mapping = ctx.userSpaceToDeviceSpaceTransform, clip = ctx.boundingBoxOfClipPath
                for glass in [GlassPaint.none, .hitArea, .placeholder(dark: nil), .placeholder(dark: false),
                              .placeholder(dark: true)] {
                    differentState(ctx)
                    let previousMatrix = ctx.textMatrix, previousPosition = ctx.textPosition
                    let borrowed = DrawTarget.capture(ctx, glass: glass)
                    let target = DrawTarget.prepareOwnedBitmap(ctx, glass: glass)
                    guard let state = target.state, let flags = state.rasterization else {
                        return t.check(false, "the explicitly established state is recorded")
                    }
                    t.equal([flags.shouldAntialias, flags.allowsAntialiasing,
                             flags.shouldSmoothFonts, flags.allowsFontSmoothing,
                             flags.shouldSubpixelPositionFonts, flags.allowsFontSubpixelPositioning,
                             flags.shouldSubpixelQuantizeFonts, flags.allowsFontSubpixelQuantization],
                            Array(repeating: true, count: 8), "\(name): the recorded flags describe the setters")
                    t.equal(state.blendMode, CGBlendMode.normal)
                    t.equal(state.interpolationQuality, .default)
                    t.equal(state.textMatrix, .identity)
                    t.equal(state.textPosition, .zero)
                    t.equal(ctx.interpolationQuality, .default)
                    t.equal(ctx.textMatrix, .identity)
                    t.equal(ctx.textPosition, .zero)
                    t.equal(target.ctm, ctm)
                    t.equal(target.userToDevice, mapping)
                    t.equal(target.colorSpace, space, "\(name): the actual profile is retained")
                    t.equal(target.glassPaint, glass)
                    t.equal(ctx.ctm, ctm, "the owned entry adds no coordinate change")
                    t.equal(ctx.userSpaceToDeviceSpaceTransform, mapping)
                    t.equal(ctx.boundingBoxOfClipPath, clip)
                    let recaptured = DrawTarget.capture(ctx, glass: glass)
                    t.check(recaptured.state?.rasterization == nil && recaptured.state?.blendMode == nil,
                            "even a prepared context cannot reveal hidden state through capture")
                    differentState(ctx)
                    t.equal(state.interpolationQuality, .default, "later setters leave the target immutable")
                    t.equal(state.textMatrix, .identity)
                    t.equal(state.textPosition, .zero)
                    t.equal(state.blendMode, CGBlendMode.normal)
                    t.equal(borrowed.state?.interpolationQuality, CGInterpolationQuality.high)
                    t.equal(borrowed.state?.textMatrix, previousMatrix)
                    t.equal(borrowed.state?.textPosition, previousPosition)
                    t.check(borrowed.state?.rasterization == nil && borrowed.state?.blendMode == nil)
                }
            }
        }
    }

    private static func bitmapSpaces() throws -> [(name: String, space: CGColorSpace)] {
        let white: [CGFloat] = [0.9505, 1, 1.089]
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let gamma22 = CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: nil, gamma: [2.2, 2.2, 2.2],
                                         matrix: nil),
              let gamma18 = CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: nil, gamma: [1.8, 1.8, 1.8],
                                         matrix: nil) else { throw CocoaError(.featureUnsupported) }
        return [("sRGB", srgb), ("Display P3", p3), ("unnamed gamma 2.2", gamma22), ("unnamed gamma 1.8", gamma18)]
    }

    private static func disableRasterization(_ ctx: CGContext) {
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSubpixelPositionFonts(false)
        ctx.setAllowsFontSubpixelPositioning(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsFontSubpixelQuantization(false)
    }

    private static func differentState(_ ctx: CGContext) {
        disableRasterization(ctx)
        ctx.interpolationQuality = .high
        ctx.setBlendMode(.copy)
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0.2, c: 0.25, d: -1, tx: 7, ty: 8)
        ctx.textPosition = CGPoint(x: 4.5, y: 6.25)
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
    private enum BitmapFormat: String, CaseIterable {
        case rgba = "RGBA", bgra = "BGRA", device = "device NSBitmap"
    }

    private static func ownedPixels(_ t: AppTestRunner) {
        t.suite("App: draw image boundary: owned scene state preserves frozen bitmap pixels across destinations") {
            guard let folder = Paths.repositoryFolder("TestSkins/Image/ImageMeters/@Resources/Images") else {
                return t.check(false, "original image fixtures")
            }
            let files = try Dictionary(uniqueKeysWithValues: ["Card.png", "Tile.png", "Mask.png"].map {
                ($0, try Data(contentsOf: folder.appendingPathComponent($0)))
            })
            guard let loaded = SkinDrawingSelfTests.load(t, SkinDrawingSelfTests.keep + "\n" + ownedFixture,
                                                         files: files, "owned-bitmap-state"),
                  let effects = loaded.skin.meter(named: "Effects") as? StringMeter,
                  let fallback = loaded.skin.meter(named: "Fallback") as? StringMeter else {
                return t.check(false, "mixed scene fixture")
            }
            let skin = loaded.skin
            defer { withExtendedLifetime(loaded.host) { skin.close() } }
            t.check(effects.style.antiAlias && !fallback.style.antiAlias, "both text antialias options are loaded")
            t.equal(effects.style.inlineSpans.count, 2, "the gradient and inline shadow are resolved")
            t.equal(fallback.style.fontFace, "No Such Font Anywhere", "the existing font fallback is exercised")
            t.check((skin.meter(named: "Masked") as? ImageMeter)?.imagePath?.isEmpty == false,
                    "the masked image source was loaded")
            for format in BitmapFormat.allCases {
                let spaces: [(String, CGColorSpace?)] = format == .device ? [("device", nil)]
                    : try bitmapSpaces().map { ($0.name, Optional($0.space)) }
                for (name, space) in spaces {
                    for scale: CGFloat in [1, 1.5, 2] {
                        let label = "\(format.rawValue) \(name) \(scale)x"
                        // Equal images can round differently after drawing into another pixel format. Each
                        // independent path starts with freshly decoded sources, as the legacy gate does.
                        Images.purge()
                        LegacyImages.purge()
                        let reference = try bitmap(format, space: space, scale: scale) {
                            LegacySkinRenderer.draw(skin, in: $0, glass: .none)
                        }
                        Images.purge()
                        LegacyImages.purge()
                        let ambient = try bitmap(format, space: space, scale: scale) {
                            SkinRenderer.draw(skin, in: $0, glass: .none)
                        }
                        Images.purge()
                        LegacyImages.purge()
                        let freshOwned = try bitmap(format, space: space, scale: scale) { ctx in
                            let target = DrawTarget.prepareOwnedBitmap(ctx, glass: .none)
                            SkinRenderer.draw(skin, in: ctx, target: target)
                        }
                        Images.purge()
                        LegacyImages.purge()
                        let owned = try bitmap(format, space: space, scale: scale) { ctx in
                            differentState(ctx)
                            let target = DrawTarget.prepareOwnedBitmap(ctx, glass: .none)
                            SkinRenderer.draw(skin, in: ctx, target: target)
                        }
                        t.check(!LegacyRenderSelfTests.isEmpty(reference) && !LegacyRenderSelfTests.isEmpty(ambient)
                                && !LegacyRenderSelfTests.isEmpty(freshOwned) && !LegacyRenderSelfTests.isEmpty(owned),
                                "\(label): every path paints visible pixels")
                        t.check(LegacyRenderSelfTests.bytesEqual(ambient, reference), "\(label): unchanged ambient pixels")
                        t.check(LegacyRenderSelfTests.bytesEqual(freshOwned, reference), "\(label): fresh policy keeps frozen pixels")
                        t.check(LegacyRenderSelfTests.bytesEqual(owned, reference), "\(label): exact frozen pixels after policy")
                        t.check(LegacyRenderSelfTests.bytesEqual(owned, freshOwned),
                                "\(label): nonzero prior text state and high interpolation do not leak into the owned scene")
                        if let space {
                            t.equal(owned.colorSpace, space, "\(label): no profile substitution")
                        }
                    }
                }
            }

            // SkinBitmapDrawing re-enters the same owned context for each uncached range. Exercise that
            // real entry point separately from the already transformed context used by --render above.
            guard let runSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                return t.check(false, "run comparison space")
            }
            // The live picture and fullDrawing paths reuse the skin's context, as the earlier destinations did.
            let runContext = SkinRenderContext.of(skin)
            for scale: CGFloat in [1, 1.5, 2] {
                let width = Int(220 * scale), height = Int(176 * scale)
                let environment = AppSceneEnvironment(scale: Double(scale), appearance: .light,
                                                      appearanceName: NSAppearance.currentDrawing().name.rawValue)
                let scene = SceneProjector().project(skin, environment: environment, glassSource: .published)
                let runs = scene.drawingRuns
                t.check(runs.count > 3, "the fixture contains independent top-level runs")
                func picture(_ context: SkinRenderContext, segmented: Bool) throws -> CGImage {
                    guard let ctx = SkinBitmapDrawing.makeContext(width, height, runSpace) else {
                        throw CocoaError(.featureUnsupported)
                    }
                    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
                    differentState(ctx)
                    let ranges = segmented ? runs.indices.map { $0..<($0 + 1) } : [0..<runs.count]
                    for range in ranges {
                        SkinBitmapDrawing.draw(items: range, runs, context: context, cycle: skin.updateCount,
                                               into: ctx, height: height, scale: scale)
                    }
                    guard let image = ctx.makeImage() else { throw CocoaError(.coderInvalidValue) }
                    return image
                }
                Images.purge()
                LegacyImages.purge()
                guard let reference = LegacySkinBitmapDrawing.fullDrawing(of: skin, width, height,
                                                                          scale: scale, space: runSpace)?.makeImage() else {
                    return t.check(false, "frozen full run picture")
                }
                Images.purge()
                LegacyImages.purge()
                let whole = try picture(runContext, segmented: false)
                Images.purge()
                LegacyImages.purge()
                let segmented = try picture(runContext, segmented: true)
                Images.purge()
                LegacyImages.purge()
                let repeated = try picture(runContext, segmented: true)
                t.check(!LegacyRenderSelfTests.isEmpty(reference) && !LegacyRenderSelfTests.isEmpty(whole)
                        && !LegacyRenderSelfTests.isEmpty(segmented) && !LegacyRenderSelfTests.isEmpty(repeated),
                        "\(scale)x: the real run entries produce visible pictures")
                t.check(LegacyRenderSelfTests.bytesEqual(whole, reference), "\(scale)x: whole owned entry matches frozen drawing")
                t.check(LegacyRenderSelfTests.bytesEqual(segmented, whole), "\(scale)x: each owned range keeps whole-scene pixels")
                t.check(LegacyRenderSelfTests.bytesEqual(repeated, segmented), "\(scale)x: warm run caches preserve the picture")

                // Independent contexts start with empty layouts on both paths. Compare the run entry with the
                // library under that same condition, separately from the associated-context Frozen comparison.
                let freshAmbient = SkinRenderContext(), freshOwned = SkinRenderContext(), freshRun = SkinRenderContext()
                t.equal([freshAmbient.text.builds, freshOwned.text.builds, freshRun.text.builds], [0, 0, 0],
                        "\(scale)x: the independent contexts start with no text layouts")
                func library(_ context: SkinRenderContext, prepared: Bool) throws -> CGImage {
                    Images.purge()
                    LegacyImages.purge()
                    return try bitmap(.bgra, space: runSpace, scale: scale, clipped: false) { ctx in
                        let target = prepared ? DrawTarget.prepareOwnedBitmap(ctx, glass: .hitArea)
                            : DrawTarget.capture(ctx, glass: .hitArea)
                        DesksetDraw.DrawExecutor.draw(scene: scene, in: ctx, context: context.drawing,
                                                     cycle: skin.updateCount, target: target)
                    }
                }
                let ambient = try library(freshAmbient, prepared: false)
                let owned = try library(freshOwned, prepared: true)
                Images.purge()
                LegacyImages.purge()
                let fresh = try picture(freshRun, segmented: false)
                t.check(!LegacyRenderSelfTests.isEmpty(ambient) && !LegacyRenderSelfTests.isEmpty(owned)
                        && !LegacyRenderSelfTests.isEmpty(fresh), "\(scale)x: every fresh-context path paints pixels")
                t.check(LegacyRenderSelfTests.bytesEqual(owned, ambient),
                        "\(scale)x: owned policy preserves fresh library pixels")
                t.check(LegacyRenderSelfTests.bytesEqual(fresh, owned),
                        "\(scale)x: the fresh run entry matches the fresh owned library")
            }

            var text = effects.lower()
            text.style.inlineSpans = []
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
                return t.check(false, "canary space")
            }
            for format in BitmapFormat.allCases {
                for glyphs in [true, false] {
                    func picture(disabled: Bool, capture: Bool) throws -> CGImage {
                        try bitmap(format, space: space, scale: 1.5, clipped: false) { ctx in
                            _ = DrawTarget.prepareOwnedBitmap(ctx, glass: .none)
                            if disabled { disableRasterization(ctx) }
                            if capture {
                                let borrowed = DrawTarget.capture(ctx, glass: .none)
                                t.check(borrowed.state?.rasterization == nil && borrowed.state?.blendMode == nil,
                                        "the borrowed canary's hidden state remains unknown")
                            }
                            if glyphs {
                                SkinRenderer.drawString(text, ctx, SkinRenderContext(), cycle: skin.updateCount)
                            } else {
                                ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.65, blue: 0.9, alpha: 0.8))
                                ctx.fillEllipse(in: CGRect(x: 12.25, y: 13.75, width: 35.5, height: 23.25))
                            }
                        }
                    }
                    let normal = try picture(disabled: false, capture: false)
                    let disabled = try picture(disabled: true, capture: false)
                    let captured = try picture(disabled: true, capture: true)
                    let label = "\(format.rawValue) \(glyphs ? "text" : "geometry") canary"
                    t.check(!LegacyRenderSelfTests.isEmpty(normal) && !LegacyRenderSelfTests.isEmpty(disabled)
                            && !LegacyRenderSelfTests.isEmpty(captured), "\(label): all three pictures are nonempty")
                    t.check(!LegacyRenderSelfTests.bytesEqual(normal, disabled), "\(label): wrong flags change actual pixels")
                    t.check(LegacyRenderSelfTests.bytesEqual(disabled, captured), "\(label): pure capture preserves borrowed state")
                }
            }
        }
    }

    /// Fresh contexts in the same stages as the owned render entry: create the bitmap, flip and scale, then
    /// make its AppKit wrapper current before the supplied scene operation. No rasterization flags are set here.
    private static func bitmap(_ format: BitmapFormat, space: CGColorSpace?, scale: CGFloat, clipped: Bool = true,
                               _ draw: (CGContext) -> Void) throws -> CGImage {
        let width = Int(220 * scale), height = Int(176 * scale)
        func paint(_ ctx: CGContext) throws -> CGImage {
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: scale, y: -scale)
            if clipped { ctx.clip(to: CGRect(x: 1.25, y: 2.5, width: 210.5, height: 163.25)) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            defer { NSGraphicsContext.restoreGraphicsState() }
            draw(ctx)
            guard let image = ctx.makeImage() else { throw CocoaError(.coderInvalidValue) }
            return image
        }
        if format == .device {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let wrapper = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.featureUnsupported) }
            return try withExtendedLifetime(rep) { try paint(wrapper.cgContext) }
        }
        let info = format == .bgra
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space, let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space, bitmapInfo: info) else {
            throw CocoaError(.featureUnsupported)
        }
        return try paint(ctx)
    }

    private static let ownedFixture = """
    [Effects]
    Meter=String
    X=5.25
    Y=97.5
    W=190
    H=30
    Padding=2.25,1.5,3.25,1.5
    FontFace=Helvetica
    FontSize=13.25
    FontColor=40,120,210,220
    Text=Fractional gradient shadow
    AntiAlias=1
    ClipString=1
    InlineSetting=GradientColor | 37 | 210,30,140,220 ; 0 | 30,160,220,200 ; 1
    InlinePattern=gradient
    InlineSetting2=Shadow | 1 | 2 | 3 | 0,0,0,180
    InlinePattern2=shadow
    [Fallback]
    Meter=String
    X=5.75
    Y=134.25
    W=190
    H=30
    FontFace=No Such Font Anywhere
    FontSize=11.25
    FontColor=180,80,40,210
    Text=Fallback 字形 café
    AntiAlias=0
    ClipString=1
    [Masked]
    Meter=Image
    X=166.25
    Y=4.75
    W=35.5
    H=28.25
    ImageName=Card.png
    MaskImageName=Mask.png
    ImageTint=180,220,160,210
    ImageAlpha=173
    [Tiled]
    Meter=Image
    X=168.25
    Y=45.25
    W=34.5
    H=36.75
    ImageName=Tile.png
    Tile=1
    ImageAlpha=173
    """

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
