import AppKit
import DesksetCore

/// An image file prepared with its general image options (see `ImageOptions`): EXIF orientation, ImageCrop and the
/// color transform are baked into `image` (cached by `Images`); ImageFlip, ImageRotate and the alpha are applied
/// when drawing. Reusable by every meter that draws image files.
struct PreparedImage {
    let path: String
    let options: ImageOptions
    /// Pixels after EXIF orientation, crop and color transform.
    let image: CGImage
    let generation: Int
    let recipe: Images.Recipe
    /// Natural size after ImageRotate (1 image pixel = 1 point).
    let size: CGSize
    /// Opacity 0…1 (ImageAlpha, else ImageTint's alpha; 1 with a ColorMatrix).
    let alpha: CGFloat

    init?(path: String, options: ImageOptions) {
        guard let p = Images.prepared(atPath: path, options: options) else { return nil }
        self.path = path
        self.options = options
        image = p.image
        generation = p.generation
        recipe = p.recipe
        let rotated = ImageOptions.rotatedSize(width: Double(p.image.width), height: Double(p.image.height),
                                               degrees: options.rotate)
        size = CGSize(width: rotated.width, height: rotated.height)
        alpha = CGFloat(options.drawAlpha / 255)
    }

    var hasTransform: Bool { options.flip != .none || options.rotate != 0 }

    /// Draws the whole image — flipped, then rotated clockwise about its center — scaled so that its rotated
    /// bounding box fills `rect` (non-uniformly when the aspect ratios differ).
    func draw(in rect: CGRect, _ ctx: CGContext, alpha override: CGFloat? = nil) {
        let a = override ?? alpha
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0, a > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        if options.rotate != 0 { ctx.concatenate(PreparedImage.rotation(degrees: options.rotate)) }
        if options.flip != .none {
            ctx.scaleBy(x: options.flip.horizontal ? -1 : 1, y: options.flip.vertical ? -1 : 1)
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        SkinRenderer.drawCGImage(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), ctx, alpha: a)
        ctx.restoreGState()
    }

    /// Clockwise rotation in the flipped (y-down) skin space; exact for multiples of 90°.
    static func rotation(degrees: Double) -> CGAffineTransform {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        let normalized = d < 0 ? d + 360 : d
        switch normalized {
        case 90: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 270: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        default: return CGAffineTransform(rotationAngle: CGFloat(d * .pi / 180))
        }
    }

    /// The image with flip and rotation baked in (for tiling and nine-slice scaling); the prepared image itself
    /// when there is nothing to bake. Cached.
    func flattened() -> CGImage? {
        guard hasTransform else { return image }
        let recipe = Images.Recipe.flattened(recipe, flipH: options.flip.horizontal, flipV: options.flip.vertical,
                                             rotate: options.rotate)
        return Images.derived(Images.DerivedKey(path: path, generation: generation, recipe: recipe)) {
            let w = Int(size.width.rounded(.up)), h = Int(size.height.rounded(.up))
            guard let ctx = Images.bitmapContext(width: w, height: h) else { return nil }
            // Draw in y-down skin coordinates.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height), ctx, alpha: 1)
            return ctx.makeImage()
        }
    }

    /// A sub-rectangle (image pixels, top-left origin) of the prepared image, cached (strip frames).
    func region(_ r: SkinRect) -> CGImage? {
        // Callers pass frame rectangles derived from the image, but this is a shared helper: never trap in Int().
        func ok(_ v: Double) -> Bool { v.isFinite && abs(v) <= ImageOptions.maxSide }
        guard ok(r.x), ok(r.y), ok(r.width), ok(r.height) else { return nil }
        let x = Int(r.x.rounded()), y = Int(r.y.rounded()), w = Int(r.width.rounded()), h = Int(r.height.rounded())
        guard w > 0, h > 0 else { return nil }
        if x == 0, y == 0, w == image.width, h == image.height { return image }
        let rect = CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(x: 0, y: 0, width: image.width,
                                                                                height: image.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let recipe = Images.Recipe.region(recipe, x: x, y: y, width: w, height: h)
        return Images.derived(Images.DerivedKey(path: path, generation: generation, recipe: recipe)) {
            image.cropping(to: rect)
        }
    }
}

extension SkinRenderer {
    // MARK: Image

    static func drawImage(_ meter: ImageMeter, _ ctx: CGContext) {
        guard let path = meter.imagePath, let prepared = PreparedImage(path: path, options: meter.imageOptions)
        else { return }
        let area = meter.contentFrame.cgRect
        guard area.width > 0, area.height > 0 else { return }
        if let maskPath = meter.maskImagePath {
            drawMasked(prepared, maskPath: maskPath, maskOptions: meter.maskOptions, in: area, ctx)
            return
        }
        drawImageFile(prepared, in: area, preserveAspectRatio: meter.preserveAspectRatio, tile: meter.tile,
                      scaleMargins: meter.scaleMargins, ctx)
    }

    /// Draws an image file with its general image options into `rect` (clipped to it):
    /// `tile` repeats it unscaled from the top-left corner; otherwise `scaleMargins` (with PreserveAspectRatio 0)
    /// nine-slices it; otherwise PreserveAspectRatio 0 stretches, 1 fits, 2 fills (see `ImageGeometry.placement`).
    static func drawImageFile(atPath path: String, options: ImageOptions, in rect: CGRect,
                              preserveAspectRatio: Int = 0, tile: Bool = false, scaleMargins: SkinInsets? = nil,
                              _ ctx: CGContext) {
        guard let prepared = PreparedImage(path: path, options: options) else { return }
        drawImageFile(prepared, in: rect, preserveAspectRatio: preserveAspectRatio, tile: tile,
                      scaleMargins: scaleMargins, ctx)
    }

    static func drawImageFile(_ prepared: PreparedImage, in rect: CGRect, preserveAspectRatio: Int = 0,
                              tile: Bool = false, scaleMargins: SkinInsets? = nil, _ ctx: CGContext) {
        guard rect.width > 0, rect.height > 0, prepared.alpha > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        if tile {
            guard let image = prepared.flattened() else { return }
            ctx.setAlpha(prepared.alpha)
            tileImage(image, in: rect, ctx)
            return
        }
        if preserveAspectRatio == 0, let margins = scaleMargins {
            guard let image = prepared.flattened() else { return }
            drawNineSlice(image, margins: margins, in: rect, ctx, alpha: prepared.alpha)
            return
        }
        let target = ImageGeometry.placement(imageWidth: Double(prepared.size.width),
                                             imageHeight: Double(prepared.size.height),
                                             in: SkinRect(x: Double(rect.minX), y: Double(rect.minY),
                                                          width: Double(rect.width), height: Double(rect.height)),
                                             preserveAspectRatio: preserveAspectRatio)
        prepared.draw(in: target.cgRect, ctx)
    }

    /// Draws one frame of a strip image (Bitmap, Button): `source` in prepared-image pixels, scaled into `dest`;
    /// ImageFlip flips the frame in place.
    static func drawImageFrame(_ prepared: PreparedImage, source: SkinRect, in dest: CGRect, _ ctx: CGContext) {
        guard dest.width > 0, dest.height > 0, prepared.alpha > 0, let frame = prepared.region(source) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if prepared.options.flip != .none {
            ctx.translateBy(x: dest.midX, y: dest.midY)
            ctx.scaleBy(x: prepared.options.flip.horizontal ? -1 : 1, y: prepared.options.flip.vertical ? -1 : 1)
            ctx.translateBy(x: -dest.midX, y: -dest.midY)
        }
        drawCGImage(frame, in: dest, ctx, alpha: prepared.alpha)
    }

    /// Repeats `image` at its pixel size over `rect`, starting at the top-left corner (one CoreGraphics call).
    static func tileImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        guard image.width > 0, image.height > 0, rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        // byTiling repeats the image from the origin in both directions; flip to y-up with the origin at the
        // rect's top-left so the first tile starts there, upright.
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        let h = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: -h, width: CGFloat(image.width), height: h), byTiling: true)
        ctx.restoreGState()
    }

    /// ScaleMargins: corners unscaled, edges stretched along one axis, center in both, drawn with `alpha`
    /// (every piece sets it: `drawCGImage` replaces the context alpha, it does not multiply it).
    static func drawNineSlice(_ image: CGImage, margins: SkinInsets, in rect: CGRect, _ ctx: CGContext,
                              alpha: CGFloat = 1) {
        let pieces = ImageGeometry.nineSlice(imageWidth: Double(image.width), imageHeight: Double(image.height),
                                             margins: margins,
                                             into: SkinRect(x: Double(rect.minX), y: Double(rect.minY),
                                                            width: Double(rect.width), height: Double(rect.height)))
        for piece in pieces {
            let s = piece.source
            let src = CGRect(x: s.x.rounded(), y: s.y.rounded(), width: s.width.rounded(), height: s.height.rounded())
            guard src.width >= 1, src.height >= 1, let part = image.cropping(to: src) else { continue }
            drawCGImage(part, in: piece.destination.cgRect, ctx, alpha: alpha)
        }
    }

    /// MaskImageName: the image fills `area` keeping its aspect ratio; the mask (with MaskImageFlip /
    /// MaskImageRotate) is stretched over `area`; each pixel keeps the smaller ("most transparent") alpha. The
    /// composite is rendered at the context's device scale and cached.
    static func drawMasked(_ prepared: PreparedImage, maskPath: String, maskOptions: ImageOptions, in area: CGRect,
                           _ ctx: CGContext) {
        guard let mask = PreparedImage(path: maskPath, options: maskOptions) else { return }
        let t = ctx.userSpaceToDeviceSpaceTransform
        // Device pixels per point, 1…4 (clamped before converting: TransformationMatrix can scale by anything).
        let deviceScale = Double(hypot(t.a, t.b))
        let scale = deviceScale.isFinite ? Int(ceil(min(max(deviceScale, 1), 4) - 0.01)) : 1
        // Sizes are checked in floating point first: a hostile W/H (e.g. W=(10**300)) must not trap in Int().
        guard let (pw, ph) = ImageGeometry.pixelSize(width: Double(area.width), height: Double(area.height),
                                                     scale: Double(scale), maxPixels: Images.maxDerivedPixels)
        else { return }
        let recipe = Images.Recipe.masked(prepared.recipe, flipH: prepared.options.flip.horizontal,
                                          flipV: prepared.options.flip.vertical, rotate: prepared.options.rotate,
                                          mask: maskPath, maskGeneration: mask.generation,
                                          maskRecipe: .flattened(mask.recipe, flipH: maskOptions.flip.horizontal,
                                                                 flipV: maskOptions.flip.vertical,
                                                                 rotate: maskOptions.rotate),
                                          width: pw, height: ph, scale: scale)
        let key = Images.DerivedKey(path: prepared.path, generation: prepared.generation, recipe: recipe)
        guard let composite = Images.derived(key, {
            composeMask(prepared, mask, width: pw, height: ph, scale: CGFloat(scale))
        }) else { return }
        drawCGImage(composite, in: area, ctx, alpha: prepared.alpha)
    }

    private static func composeMask(_ image: PreparedImage, _ mask: PreparedImage, width pw: Int, height ph: Int,
                                    scale: CGFloat) -> CGImage? {
        guard let ci = Images.bitmapContext(width: pw, height: ph), let cm = Images.bitmapContext(width: pw, height: ph)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(pw) / scale, height: CGFloat(ph) / scale)
        for c in [ci, cm] {
            c.translateBy(x: 0, y: CGFloat(ph))
            c.scaleBy(x: scale, y: -scale)
        }
        let fill = ImageGeometry.placement(imageWidth: Double(image.size.width), imageHeight: Double(image.size.height),
                                           in: SkinRect(x: 0, y: 0, width: Double(bounds.width),
                                                        height: Double(bounds.height)),
                                           preserveAspectRatio: 2)
        ci.clip(to: bounds)
        image.draw(in: fill.cgRect, ci, alpha: 1)
        mask.draw(in: bounds, cm, alpha: 1)
        guard let di = ci.data?.assumingMemoryBound(to: UInt8.self),
              let dm = cm.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for i in 0..<(pw * ph) {
            let o = i * 4
            let a = Int(di[o + 3]), m = Int(dm[o + 3])
            guard m < a else { continue }
            if m == 0 {
                di[o] = 0; di[o + 1] = 0; di[o + 2] = 0; di[o + 3] = 0
            } else {
                // Premultiplied: scale the color with the alpha.
                di[o] = UInt8((Int(di[o]) * m + a / 2) / a)
                di[o + 1] = UInt8((Int(di[o + 1]) * m + a / 2) / a)
                di[o + 2] = UInt8((Int(di[o + 2]) * m + a / 2) / a)
                di[o + 3] = UInt8(m)
            }
        }
        return ci.makeImage()
    }

    /// ImageTint multiplies the image colors by the tint; its alpha scales opacity.
    /// (Kept for callers that tint a CGImage directly; image files should use `drawImageFile` instead.)
    static func drawTinted(_ image: CGImage, in rect: CGRect, tint: RGBA?, greyscale: Bool, alpha: CGFloat,
                                   _ ctx: CGContext) {
        ctx.saveGState()
        ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        drawCGImage(image, in: rect, ctx)
        if greyscale {
            ctx.setBlendMode(.saturation)
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(rect)
        }
        if let tint {
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(RGBA(r: tint.r, g: tint.g, b: tint.b).cgColor)
            ctx.fill(rect)
        }
        // Restore the original alpha mask.
        ctx.setBlendMode(.destinationIn)
        drawCGImage(image, in: rect, ctx, alpha: alpha * CGFloat((tint?.a ?? 255) / 255))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
