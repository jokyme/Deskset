import CoreGraphics

/// Captured destination facts, without retaining or changing its graphics context.
/// Each drawing operation captures its current mapping after applying its local transforms.
public struct DrawTarget {
    public let userToDevice: CGAffineTransform
    /// The actual destination space, when CoreGraphics exposes it. Nil is not a request for an sRGB fallback.
    public let colorSpace: CGColorSpace?
    public let glassPaint: GlassPaint
    /// Readable graphics state at capture time; nil for a target constructed from a mapping alone.
    /// Font rasterization flags and the current blend mode have no CoreGraphics getters and are not inferred here.
    public let state: State?

    public struct State {
        public let interpolationQuality: CGInterpolationQuality
        public let textMatrix: CGAffineTransform
        public let textPosition: CGPoint
    }

    /// CoreGraphics' current transform, which can differ from the device mapping in a display-list context.
    package let ctm: CGAffineTransform
    /// The native round-trip correction for the captured graph anchor. Nil means no anchor or a rejected snap;
    /// `.some(.zero)` is an accepted zero translation and must still reach `translateBy`.
    package let graphTranslation: CGPoint?

    /// An explicit mapping for density calculations. Its CTM describes the same supplied mapping; drawing that
    /// needs the context's actual CTM, such as inline text shadows, uses `capture` instead.
    public init(userToDevice: CGAffineTransform) {
        self.init(ctm: userToDevice, userToDevice: userToDevice, graphTranslation: nil,
                  colorSpace: nil, glassPaint: .none, state: nil)
    }

    private init(ctm: CGAffineTransform, userToDevice: CGAffineTransform, graphTranslation: CGPoint?,
                 colorSpace: CGColorSpace?, glassPaint: GlassPaint, state: State?) {
        self.ctm = ctm
        self.userToDevice = userToDevice
        self.graphTranslation = graphTranslation
        self.colorSpace = colorSpace
        self.glassPaint = glassPaint
        self.state = state
    }

    /// Capture the drawing destination at its entry point. Borrowed AppKit contexts keep their inherited
    /// state and coordinate system; capturing never resets flags, substitutes a color space or adds a y flip.
    public static func capture(_ ctx: CGContext, glass: GlassPaint) -> DrawTarget {
        DrawTarget(ctm: ctx.ctm, userToDevice: ctx.userSpaceToDeviceSpaceTransform, graphTranslation: nil,
                   colorSpace: ctx.colorSpace, glassPaint: glass,
                   state: State(interpolationQuality: ctx.interpolationQuality,
                                textMatrix: ctx.textMatrix, textPosition: ctx.textPosition))
    }

    /// Capture at the drawing operation's current transform, after its local transforms have been applied.
    /// Graph snapping keeps CoreGraphics' native point round trip: applying an inverted captured transform can
    /// round differently and change the strict acceptance gates. The target retains only values, not the context.
    package static func capture(_ ctx: CGContext, graphAnchor: CGPoint? = nil) -> DrawTarget {
        let ctm = ctx.ctm
        let userToDevice = ctx.userSpaceToDeviceSpaceTransform
        let graphTranslation = graphAnchor.flatMap { origin -> CGPoint? in
            let device = ctx.convertToDeviceSpace(origin)
            guard device.x.isFinite, device.y.isFinite, abs(device.x) < 1e9, abs(device.y) < 1e9 else { return nil }
            let aligned = ctx.convertToUserSpace(CGPoint(x: device.x.rounded(), y: device.y.rounded()))
            let dx = aligned.x - origin.x, dy = aligned.y - origin.y
            guard dx.isFinite, dy.isFinite, abs(dx) < 1, abs(dy) < 1 else { return nil }
            return CGPoint(x: dx, y: dy)
        }
        return DrawTarget(ctm: ctm, userToDevice: userToDevice, graphTranslation: graphTranslation,
                          colorSpace: nil, glassPaint: .none, state: nil)
    }

    /// Length of the transformed horizontal unit vector, used by image-mask composites.
    public var horizontalPixelsPerPoint: CGFloat {
        hypot(userToDevice.a, userToDevice.b)
    }

    /// Larger of the two transformed unit-vector lengths, used by image decoding and symbol rasterization.
    public var maximumPixelsPerPoint: CGFloat {
        max(horizontalPixelsPerPoint, hypot(userToDevice.c, userToDevice.d))
    }
}
