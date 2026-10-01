import CoreGraphics
import DesksetCore

/// Resource-backed drawing supplied by the platform while those painters remain outside this module.
/// Every leaf is required and runs synchronously in the executor's current transform, clip and transparency layer.
/// Implementations retain drawing services and caches only, never live engine owners.
public protocol ResourceLeafDrawing {
    func draw(_ value: TextDraw, in ctx: CGContext, cycle: Int)
    func draw(_ value: ImageDraw, in ctx: CGContext)
    func draw(_ value: BarDraw, in ctx: CGContext)
    func draw(_ value: GraphDraw, in ctx: CGContext)
    func draw(_ value: RotatorDraw, in ctx: CGContext)
    func draw(_ value: SpriteDraw, in ctx: CGContext)
}
