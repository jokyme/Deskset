import AppKit
import DesksetCore
import DesksetDraw

/// Draws a skin into the current (flipped, top-left origin) graphics context.
enum SkinRenderer {
    /// Meters in file order. Content meters (`Container=`) are drawn where their container is in that order, clipped
    /// to the container's W×H and "only drawn on solid pixels of the container"; "the container meter itself is not
    /// drawn, just the content", and "any transparency of both the container and the content is cumulative"
    /// (manual: Container). Content of a hidden container is not drawn.
    ///
    /// Glass (`MacGlass`) is behind everything the skin draws: the skin window has the real thing behind its drawing
    /// (`glass: .window`), every other drawing shows a stand-in (`GlassPlaceholder`).
    ///
    /// Only the skin's owner may draw it: drawing uses and fills the skin's `SkinRenderContext`.
    static func draw(_ skin: Skin, in ctx: CGContext, glass: GlassDrawing = .placeholder(dark: nil)) {
        let context = SkinRenderContext.of(skin)
        let scene = context.sceneProjector.project(skin, environment: sceneEnvironment(skin, ctx),
                                                  glassSource: glass == .window ? .published : .current)
        DrawExecutor.draw(scene: scene, in: ctx, context: context, cycle: skin.updateCount, glass: glass)
    }

    /// What `draw` puts under the meters: the glass (or where it catches the mouse) and the skin's background.
    static func drawBase(_ skin: Skin, in ctx: CGContext, glass: GlassDrawing) {
        let context = SkinRenderContext.of(skin)
        let scene = context.sceneProjector.project(skin, environment: sceneEnvironment(skin, ctx),
                                                  glassSource: glass == .window ? .published : .current)
        DrawExecutor.draw(scene.background, in: ctx, context: context, cycle: skin.updateCount, glass: glass)
    }

    /// Captured drawing facts for the owner-side adapters. The execution layer receives only the resulting values.
    static func sceneEnvironment(_ skin: Skin, _ ctx: CGContext) -> AppSceneEnvironment {
        let target = DrawTarget(userToDevice: ctx.userSpaceToDeviceSpaceTransform)
        return AppSceneEnvironment(scale: Double(target.maximumPixelsPerPoint),
                                   appearance: skin.host?.environment(for: skin).appearance ?? .light,
                                   appearanceName: NSAppearance.currentDrawing().name.rawValue)
    }

    /// The meters `draw` draws itself, in order: the visible ones outside containers (a container draws its content).
    static func topLevelMeters(_ skin: Skin) -> [Meter] {
        skin.meters.filter { !$0.hidden && $0.container == nil }
    }

    /// The content of a container (every meter whose Container it is, hidden or not).
    static func content(of container: Meter, in skin: Skin) -> [Meter] {
        skin.meters.filter { $0.container === container }
    }

    /// One of `topLevelMeters`, as `draw` draws it.
    static func drawTopLevel(_ meter: Meter, of skin: Skin, in ctx: CGContext, _ context: SkinRenderContext) {
        guard let index = skin.meters.firstIndex(where: { $0 === meter }) else { return }
        let scene = context.sceneProjector.project(skin, environment: sceneEnvironment(skin, ctx), glassSource: .published)
        DrawExecutor.draw(scene.drawingItems(for: scene.elements[index]), in: ctx, context: context,
                          cycle: skin.updateCount, glass: .window)
    }

    /// How glass appears in a drawing (see `draw`).
    enum GlassDrawing: Equatable {
        /// A stand-in for the glass (`GlassPlaceholder`); `dark`: over a dark background, a light one, or unknown.
        case placeholder(dark: Bool?)
        /// The skin window: the real glass is behind the drawing, which only makes it catch the mouse.
        case window
        /// No glass at all.
        case none
    }

    /// One meter with its background, bevel and TransformationMatrix (the Skin Studio's thumbnails of single layers),
    /// its glass as a stand-in. Only the owner of the meter's skin may draw it.
    static func drawMeter(_ meter: Meter, _ ctx: CGContext, glassDark: Bool? = nil) {
        drawMeters([meter], ctx, glassDark: glassDark)
    }

    /// Several meters into one picture, in the given order (the Skin Studio's thumbnails of runs and selections):
    /// first the glass stand-ins of all of them, then the meters, so the glass stays behind everything drawn, as in
    /// the skin window. Only the owner of the meters' skin may draw them.
    static func drawMeters(_ meters: [Meter], _ ctx: CGContext, glassDark: Bool? = nil) {
        let captured = meters.enumerated().map { index, meter in
            let context = SkinRenderContext.of(meter.skin)
            let element = context.sceneProjector.projectElement(meter, index: index,
                                                               environment: sceneEnvironment(meter.skin, ctx))
            return (element: element, context: context, cycle: meter.skin.updateCount)
        }
        for value in captured {
            if let region = value.element.glass {
                DrawExecutor.draw([.glass(region)], in: ctx, context: value.context, cycle: value.cycle,
                                  glass: .placeholder(dark: glassDark))
            }
        }
        for value in captured {
            DrawExecutor.draw(value.element.items, in: ctx, context: value.context, cycle: value.cycle,
                              glass: .placeholder(dark: glassDark))
        }
    }

    // MARK: Background primitives

    static func fill(_ rect: CGRect, _ c1: RGBA, _ c2: RGBA?, angle: Double, _ ctx: CGContext) {
        DrawPrimitives.fill(rect, c1, c2, angle: angle, ctx)
    }

    /// `BevelType` 1 (raised) / 2 (sunken): one-point lines along the edges. Manual: for a raised bevel "BevelColor
    /// will represent the color on the left and top edges … BevelColor2 … on the right and bottom"; for a sunken
    /// one BevelColor is on the right and bottom and BevelColor2 on the left and top. Defaults: white / black. The
    /// context is flipped, so the top edge is at `minY`.
    static func drawBevel(_ rect: CGRect, _ type: Int, light: RGBA?, dark: RGBA?, _ ctx: CGContext) {
        DrawPrimitives.drawBevel(rect, type, light: light, dark: dark, ctx)
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
    static func tile(_ image: CGImage, in rect: CGRect, _ ctx: CGContext, density: Images.Density = .one) {
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
        let w = CGFloat(image.width) / density.x, h = CGFloat(image.height) / density.y
        // Integer tiles at the backing scale: `.none` gives exactly what drawing each tile did (checked pixel by
        // pixel at 4x); smoothing would blur the pattern. (A symbol, rendered at the backing scale, is smoothed.)
        ctx.interpolationQuality = density == .one ? .none : .high
        ctx.draw(image, in: CGRect(x: rect.minX, y: rect.maxY - h, width: w, height: h), byTiling: true)
        ctx.restoreGState()
    }
}
