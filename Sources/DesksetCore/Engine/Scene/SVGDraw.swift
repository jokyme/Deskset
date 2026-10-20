import Foundation

/// A captured SVG document. Its resources and geometry are values; drawing never accesses a live meter.
public struct SVGDraw: Equatable, Sendable {
    public let sourceID: UUID
    public let revision: Int
    public var contentFrame: SkinRect
    public let nodes: [SVGRenderNode]

    /// The same source and revision must always identify the same nodes; placement may change independently.
    public init(sourceID: UUID = UUID(), revision: Int = 0, contentFrame: SkinRect, nodes: [SVGRenderNode]) {
        self.sourceID = sourceID
        self.revision = revision
        self.contentFrame = contentFrame
        self.nodes = nodes
    }

    public static func == (lhs: SVGDraw, rhs: SVGDraw) -> Bool {
        lhs.sourceID == rhs.sourceID && lhs.revision == rhs.revision && lhs.contentFrame == rhs.contentFrame
    }
}

public indirect enum SVGRenderNode: Equatable, Sendable {
    /// Opacity composites the complete group once, after its children have been painted.
    case group(transform: ShapeTransform, opacity: Double, clip: SVGClip?, children: [SVGRenderNode])
    case path(SVGPathDraw)
    case image(SVGImageDraw)
}

public struct SVGPathDraw: Equatable, Sendable {
    public var path: ShapePath
    public var fill: SVGPaint
    public var stroke: SVGPaint
    public var strokeStyle: ShapeStrokeStyle
    public var fillOpacity: Double
    public var strokeOpacity: Double

    public init(path: ShapePath, fill: SVGPaint, stroke: SVGPaint, strokeStyle: ShapeStrokeStyle,
                fillOpacity: Double = 1, strokeOpacity: Double = 1) {
        self.path = path
        self.fill = fill
        self.stroke = stroke
        self.strokeStyle = strokeStyle
        self.fillOpacity = fillOpacity
        self.strokeOpacity = strokeOpacity
    }
}

public enum SVGCoordinateUnits: Equatable, Sendable { case objectBoundingBox, userSpaceOnUse }
public enum SVGSpreadMethod: Equatable, Sendable { case pad, reflect, `repeat` }

public struct SVGGradient: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case linear(start: ShapePoint, end: ShapePoint)
        case radial(center: ShapePoint, focus: ShapePoint, radius: Double)
    }

    public var kind: Kind
    public var units: SVGCoordinateUnits
    public var transform: ShapeTransform
    public var spread: SVGSpreadMethod
    public var stops: [ShapeGradientStop]

    public init(kind: Kind, units: SVGCoordinateUnits = .objectBoundingBox,
                transform: ShapeTransform = .identity, spread: SVGSpreadMethod = .pad,
                stops: [ShapeGradientStop]) {
        self.kind = kind
        self.units = units
        self.transform = transform
        self.spread = spread
        self.stops = stops
    }
}

public enum SVGPaint: Equatable, Sendable {
    case none
    case color(RGBA)
    case gradient(SVGGradient)
}

/// Clip children are united; a group's own clip intersects that union. Paint and opacity do not affect clips.
public struct SVGClip: Equatable, Sendable {
    public var units: SVGCoordinateUnits
    public var transform: ShapeTransform
    public var children: [SVGClipNode]

    public init(units: SVGCoordinateUnits = .userSpaceOnUse, transform: ShapeTransform = .identity,
                children: [SVGClipNode]) {
        self.units = units
        self.transform = transform
        self.children = children
    }
}

public indirect enum SVGClipNode: Equatable, Sendable {
    case group(transform: ShapeTransform, clip: SVGClip?, children: [SVGClipNode])
    case path(ShapePath)
}

public struct SVGPreserveAspectRatio: Equatable, Sendable {
    public enum Alignment: Double, Equatable, Sendable { case min = 0, mid = 0.5, max = 1 }
    public var x: Alignment
    public var y: Alignment
    public var slice: Bool
    public var none: Bool

    public init(x: Alignment = .mid, y: Alignment = .mid, slice: Bool = false, none: Bool = false) {
        self.x = x
        self.y = y
        self.slice = slice
        self.none = none
    }
}

public struct SVGImageDraw: Equatable, Sendable {
    /// Only decoded base64 data is captured. File paths and network URLs are never image resources here.
    public var data: Data
    public var rect: SkinRect
    public var preserveAspectRatio: SVGPreserveAspectRatio

    public init(data: Data, rect: SkinRect, preserveAspectRatio: SVGPreserveAspectRatio = SVGPreserveAspectRatio()) {
        self.data = data
        self.rect = rect
        self.preserveAspectRatio = preserveAspectRatio
    }
}
