import AppKit
import DesksetCore

/// Draws a skin into the current (flipped, top-left origin) graphics context.
enum SkinRenderer {
    /// Meters in file order. Content meters (`Container=`) are drawn where their container is in that order, clipped
    /// to the container's W×H and "only drawn on solid pixels of the container"; "the container meter itself is not
    /// drawn, just the content", and "any transparency of both the container and the content is cumulative"
    /// (manual: Container). Content of a hidden container is not drawn.
    ///
    /// Only the skin's owner may draw it: drawing uses and fills the skin's `SkinRenderContext`.
    static func draw(_ skin: Skin, in ctx: CGContext) {
        let context = SkinRenderContext.of(skin)
        drawBackground(skin, ctx)
        for meter in skin.meters where !meter.hidden && meter.container == nil {
            if meter.isContainer {
                drawContainer(meter, content: skin.meters.filter { $0.container === meter }, ctx, context)
            } else {
                drawMeter(meter, ctx, context)
            }
        }
    }

    /// One meter with its background, bevel and TransformationMatrix (the Skin Studio's thumbnails of single layers).
    /// Only the owner of the meter's skin may draw it.
    static func drawMeter(_ meter: Meter, _ ctx: CGContext) {
        drawMeter(meter, ctx, SkinRenderContext.of(meter.skin))
    }

    private static func drawMeter(_ meter: Meter, _ ctx: CGContext, _ context: SkinRenderContext) {
        ctx.saveGState()
        if let m = meter.transformationMatrix {
            ctx.concatenate(CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]))
        }
        drawMeterBackground(meter, ctx)
        switch meter {
        case let m as StringMeter: drawString(m, ctx, context)
        case let m as ImageMeter: drawImage(m, ctx)
        case let m as BarMeter: drawBar(m, ctx)
        case let m as LineMeter: drawLine(m, ctx)
        case let m as HistogramMeter: drawHistogram(m, ctx, context)
        case let m as RoundlineMeter: drawRoundline(m, ctx)
        case let m as RotatorMeter: drawRotator(m, ctx, context)
        case let m as ShapeMeter: drawShape(m, ctx)
        case let m as ButtonMeter: drawButton(m, ctx)
        case let m as BitmapMeter: drawBitmap(m, ctx)
        default: break
        }
        ctx.restoreGState()
    }

    /// The content of `container`: drawn into a layer clipped to the container's frame, then kept only where the
    /// container's own drawing (background, image, shape… as one layer) is opaque, scaled by its alpha.
    private static func drawContainer(_ container: Meter, content: [Meter], _ ctx: CGContext,
                                      _ context: SkinRenderContext) {
        let visible = content.filter { !$0.hidden }
        let clip = container.frame.cgRect
        guard !visible.isEmpty, clip.width > 0, clip.height > 0, clip.minX.isFinite, clip.minY.isFinite else { return }
        ctx.saveGState()
        ctx.clip(to: clip)
        ctx.beginTransparencyLayer(in: clip, auxiliaryInfo: nil)
        for meter in visible { drawMeter(meter, ctx, context) }
        // The container's drawing is one layer composited with destination-in: only its alpha matters, and several
        // drawing operations (fill, bevel, image…) act as one mask.
        ctx.setBlendMode(.destinationIn)
        ctx.beginTransparencyLayer(in: clip, auxiliaryInfo: nil)
        drawMeter(container, ctx, context)
        ctx.endTransparencyLayer()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: Backgrounds

    /// `BackgroundMode`: 0 the image at its size, 2 SolidColor (with SolidColor2 / GradientAngle and the bevel),
    /// 3 the image scaled to the skin (with `BackgroundMargins` unscaled, like ScaleMargins), 4 the image tiled.
    /// "All general image options are valid for Background."
    private static func drawBackground(_ skin: Skin, _ ctx: CGContext) {
        let s = skin.settings
        let rect = CGRect(x: 0, y: 0, width: skin.width, height: skin.height)
        switch s.backgroundMode {
        case 2:
            fill(rect, s.solidColor, s.solidColor2, angle: s.gradientAngle, ctx)
            drawBevel(rect, s.bevelType, light: s.bevelColor, dark: s.bevelColor2, ctx)
        case 0, 3, 4:
            guard let path = s.backgroundImage else { return }
            guard let prepared = PreparedImage(path: path, options: s.backgroundImageOptions) else { return }
            switch s.backgroundMode {
            case 4:
                // One tiled draw with whole-pixel tiles (see `tile`), with the image options baked in.
                guard let image = prepared.flattened(), prepared.alpha > 0 else { return }
                ctx.saveGState()
                ctx.setAlpha(prepared.alpha)
                tile(image, in: rect, ctx)
                ctx.restoreGState()
            case 3:
                let m = s.backgroundMargins
                let margins = m.left != 0 || m.top != 0 || m.right != 0 || m.bottom != 0 ? m : nil
                drawImageFile(prepared, in: rect, scaleMargins: margins, ctx)
            default:
                prepared.draw(in: CGRect(origin: .zero, size: prepared.size), ctx)
            }
        default:
            break
        }
    }

    private static func drawMeterBackground(_ meter: Meter, _ ctx: CGContext) {
        let rect = meter.frame.cgRect
        if meter.solidColor.a > 0 || (meter.solidColor2?.a ?? 0) > 0 {
            fill(rect, meter.solidColor, meter.solidColor2, angle: meter.gradientAngle, ctx)
        }
        drawBevel(rect, meter.bevelType, light: meter.bevelColor, dark: meter.bevelColor2, ctx)
    }

    static func fill(_ rect: CGRect, _ c1: RGBA, _ c2: RGBA?, angle: Double, _ ctx: CGContext) {
        guard let c2, c2 != c1 else {
            ctx.setFillColor(c1.cgColor)
            ctx.fill(rect)
            return
        }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [c1.cgColor, c2.cgColor] as CFArray, locations: [0, 1])
        else { return }
        let radians = angle * .pi / 180
        let dx = cos(radians) * rect.width / 2
        let dy = sin(radians) * rect.height / 2
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX - dx, y: rect.midY - dy),
                               end: CGPoint(x: rect.midX + dx, y: rect.midY + dy),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// `BevelType` 1 (raised) / 2 (sunken): one-point lines along the edges. Manual: for a raised bevel "BevelColor
    /// will represent the color on the left and top edges … BevelColor2 … on the right and bottom"; for a sunken
    /// one BevelColor is on the right and bottom and BevelColor2 on the left and top. Defaults: white / black. The
    /// context is flipped, so the top edge is at `minY`.
    static func drawBevel(_ rect: CGRect, _ type: Int, light: RGBA?, dark: RGBA?, _ ctx: CGContext) {
        guard type == 1 || type == 2, rect.width > 1, rect.height > 1 else { return }
        let first = (light ?? RGBA(r: 255, g: 255, b: 255, a: 255)).cgColor
        let second = (dark ?? RGBA(r: 0, g: 0, b: 0, a: 255)).cgColor
        let (topLeft, bottomRight) = type == 1 ? (first, second) : (second, first)
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(topLeft)
        ctx.strokeLineSegments(between: [CGPoint(x: rect.minX, y: rect.minY + 0.5), CGPoint(x: rect.maxX, y: rect.minY + 0.5),
                                         CGPoint(x: rect.minX + 0.5, y: rect.minY), CGPoint(x: rect.minX + 0.5, y: rect.maxY)])
        ctx.setStrokeColor(bottomRight)
        ctx.strokeLineSegments(between: [CGPoint(x: rect.minX, y: rect.maxY - 0.5), CGPoint(x: rect.maxX, y: rect.maxY - 0.5),
                                         CGPoint(x: rect.maxX - 0.5, y: rect.minY), CGPoint(x: rect.maxX - 0.5, y: rect.maxY)])
        ctx.restoreGState()
    }

    // MARK: Images

    /// Draws a CGImage upright into a flipped context.
    static func drawCGImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// Tiles `image` over `rect`, the first tile at its top-left corner, tiles upright. CoreGraphics does the tiling
    /// in one call and only for the visible (clipped) area: drawing tile by tile took one draw call per tile, i.e. a
    /// million calls per frame for a 1×1 image on a 1000×1000 skin, and practically forever for huge skin sizes.
    static func tile(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        guard image.width > 0, image.height > 0, rect.width > 0, rect.height > 0,
              rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return }
        let area = rect.intersection(ctx.boundingBoxOfClipPath)
        guard !area.isNull, !area.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: area)
        // Flip the context around the rect (top-left origin → bottom-left) so images are drawn upright; the tile
        // whose top edge is the rect's top edge anchors the pattern.
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Integer tiles at the backing scale: `.none` gives exactly what drawing each tile did (checked pixel by
        // pixel at 4x); smoothing would blur the pattern.
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: rect.minX, y: rect.maxY - h, width: w, height: h), byTiling: true)
        ctx.restoreGState()
    }
}
