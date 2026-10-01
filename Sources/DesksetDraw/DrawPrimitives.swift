import CoreGraphics
import Foundation
import DesksetCore

/// Shared background painting in a flipped, top-left-origin graphics context.
package enum DrawPrimitives {
    package static func fill(_ rect: CGRect, _ c1: RGBA, _ c2: RGBA?, angle: Double, _ ctx: CGContext) {
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
    package static func drawBevel(_ rect: CGRect, _ type: Int, light: RGBA?, dark: RGBA?, _ ctx: CGContext) {
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
}
