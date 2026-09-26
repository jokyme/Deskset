import AppKit
import DesksetCore

extension SkinRenderer {
    // MARK: Histogram

    /// Collects the primary-only / secondary-only / overlap rectangles of every column (from `HistogramMeter`)
    /// and paints each part with its image (revealed through the rectangles) or its color. The rectangles go into
    /// the skin's scratch buffers (`SkinRenderContext.histogramParts`), reused from frame to frame.
    static func drawHistogram(_ meter: HistogramMeter, _ ctx: CGContext, _ context: SkinRenderContext) {
        let area = meter.contentFrame.cgRect
        let count = meter.historyLength
        guard area.width > 0, area.height > 0, count > 0 else { return }

        for i in context.histogramParts.indices { context.histogramParts[i].removeAll(keepingCapacity: true) }
        for age in 0..<count {
            let c = meter.columnRects(age: age)
            if c.primary.width > 0, c.primary.height > 0 { context.histogramParts[0].append(c.primary.cgRect) }
            if c.secondary.width > 0, c.secondary.height > 0 { context.histogramParts[1].append(c.secondary.cgRect) }
            if c.both.width > 0, c.both.height > 0 { context.histogramParts[2].append(c.both.cgRect) }
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        // AntiAlias=0: whole-pixel columns must cover whole device pixels even at X=10.5 (see LineRenderer).
        if !meter.antiAlias { alignGraphToDevicePixels(graphAnchor(area, meter.direction), ctx) }
        ctx.setShouldAntialias(meter.antiAlias)  // before clipping: an aliased graph gets an aliased clip edge
        ctx.clip(to: area)
        let parts = context.histogramParts
        drawHistogramPart(parts[0], meter.primaryColor, meter.primaryImage, area, ctx, context)
        drawHistogramPart(parts[1], meter.secondaryColor, meter.secondaryImage, area, ctx, context)
        drawHistogramPart(parts[2], meter.bothColor, meter.bothImage, area, ctx, context)
    }

    private static func drawHistogramPart(_ rects: [CGRect], _ color: RGBA, _ image: HistogramMeter.HistogramImage?,
                                          _ area: CGRect, _ ctx: CGContext, _ context: SkinRenderContext) {
        guard !rects.isEmpty else { return }
        guard let image, var cg = Images.cgImage(atPath: image.path) else {
            guard color.a > 0 else { return }
            ctx.setFillColor(color.cgColor)
            ctx.fill(rects)
            return
        }
        if let crop = image.cropRect(imageWidth: Double(cg.width), imageHeight: Double(cg.height)) {
            let rect = crop.cgRect
            if let hit = context.histogramCrops[image.path], hit.source === cg, hit.rect == rect {
                cg = hit.cropped
            } else if let cropped = cg.cropping(to: rect) {
                if context.histogramCrops.count >= SkinRenderContext.maxHistogramCrops {
                    context.histogramCrops.removeAll()
                }
                context.histogramCrops[image.path] = (cg, rect, cropped)
                cg = cropped
            } else {
                return  // the crop lies outside the image: nothing to reveal (not the whole, uncropped image)
            }
        }
        ctx.saveGState()
        ctx.clip(to: rects)
        if image.flipHorizontal || image.flipVertical {
            ctx.translateBy(x: area.midX, y: area.midY)
            ctx.scaleBy(x: image.flipHorizontal ? -1 : 1, y: image.flipVertical ? -1 : 1)
            ctx.translateBy(x: -area.midX, y: -area.midY)
        }
        let alpha = CGFloat(image.alpha / 255)
        if image.greyscale || image.tint != nil {
            drawHistogramTinted(cg, in: area, tint: image.tint, greyscale: image.greyscale, alpha: alpha, ctx)
        } else {
            drawCGImage(cg, in: area, ctx, alpha: alpha)
        }
        ctx.restoreGState()
    }

    /// Greyscale and/or tint (multiply) with the image's own alpha mask kept (General Image Options: Greyscale +
    /// ImageTint recolors the image; ImageTint alone tints it).
    private static func drawHistogramTinted(_ image: CGImage, in rect: CGRect, tint: RGBA?, greyscale: Bool,
                                            alpha: CGFloat, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        drawCGImage(image, in: rect, ctx)
        if greyscale {
            ctx.setBlendMode(.saturation)
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(rect)
        }
        if let tint {
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(tint.cgColor)
            ctx.fill(rect)
        }
        ctx.setBlendMode(.destinationIn)
        drawCGImage(image, in: rect, ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
