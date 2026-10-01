import CoreGraphics
import DesksetCore

package enum HistogramRenderer {
    // MARK: Histogram

    /// Collects the primary-only / secondary-only / overlap rectangles of every captured column
    /// and paints each part with its image (revealed through the rectangles) or its color. The rectangles go into
    /// the skin's scratch buffers (`SkinRenderContext.histogramParts`), reused from frame to frame.
    package static func draw(_ drawing: HistogramDraw, in ctx: CGContext, cache: HistogramCache) {
        let area = drawing.contentFrame.cgRect
        let count = drawing.historyLength
        guard area.width > 0, area.height > 0, count > 0 else { return }

        for i in cache.parts.indices { cache.parts[i].removeAll(keepingCapacity: true) }
        for age in 0..<count {
            let c = drawing.columnRects(age: age)
            if c.primary.width > 0, c.primary.height > 0 { cache.parts[0].append(c.primary.cgRect) }
            if c.secondary.width > 0, c.secondary.height > 0 { cache.parts[1].append(c.secondary.cgRect) }
            if c.both.width > 0, c.both.height > 0 { cache.parts[2].append(c.both.cgRect) }
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        // AntiAlias=0: whole-pixel columns must cover whole device pixels even at X=10.5 (see LineRenderer).
        if !drawing.antiAlias { LineRenderer.alignGraphToDevicePixels(LineRenderer.graphAnchor(area, drawing.direction), ctx) }
        ctx.setShouldAntialias(drawing.antiAlias)  // before clipping: an aliased graph gets an aliased clip edge
        ctx.clip(to: area)
        let parts = cache.parts
        drawHistogramPart(parts[0], drawing.primaryColor, drawing.primaryImage, area, ctx, cache)
        drawHistogramPart(parts[1], drawing.secondaryColor, drawing.secondaryImage, area, ctx, cache)
        drawHistogramPart(parts[2], drawing.bothColor, drawing.bothImage, area, ctx, cache)
    }

    private static func drawHistogramPart(_ rects: [CGRect], _ color: RGBA, _ image: HistogramMeter.HistogramImage?,
                                          _ area: CGRect, _ ctx: CGContext, _ cache: HistogramCache) {
        guard !rects.isEmpty else { return }
        guard let image, var cg = Images.cgImage(atPath: image.path) else {
            guard color.a > 0 else { return }
            ctx.setFillColor(color.cgColor)
            ctx.fill(rects)
            return
        }
        if let crop = image.cropRect(imageWidth: Double(cg.width), imageHeight: Double(cg.height)) {
            let rect = crop.cgRect
            if let hit = cache.crops[image.path], hit.source === cg, hit.rect == rect {
                cg = hit.cropped
            } else if let cropped = cg.cropping(to: rect) {
                if cache.crops.count >= HistogramCache.maxCrops {
                    cache.crops.removeAll()
                }
                cache.crops[image.path] = (cg, rect, cropped)
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
            ImageRenderer.drawCGImage(cg, in: area, ctx, alpha: alpha)
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
        ImageRenderer.drawCGImage(image, in: rect, ctx)
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
        ImageRenderer.drawCGImage(image, in: rect, ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// Scratch rectangles and decoded-image crops reused by one drawing owner.
package final class HistogramCache {
    package var parts: [[CGRect]] = [[], [], []]
    package var crops: [String: (source: CGImage, rect: CGRect, cropped: CGImage)] = [:]
    package static let maxCrops = 64

    package init() {}
}
