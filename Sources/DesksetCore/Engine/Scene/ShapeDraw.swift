import Foundation

/// A Shape meter's immutable payload and placement for one frame. The source and revision identify the payload
/// without comparing its paths on every frame; prepared drawing paths belong to the renderer's context.
public struct ShapeDraw: Equatable, Sendable {
    public let sourceID: UUID
    public let revision: Int
    public let shapes: [ShapeItem]
    public var contentFrame: SkinRect

    /// A new independent payload. Its identity cannot be reused with different shapes.
    public init(shapes: [ShapeItem], contentFrame: SkinRect) {
        self.init(sourceID: UUID(), revision: 0, shapes: shapes, contentFrame: contentFrame)
    }

    init(sourceID: UUID, revision: Int, shapes: [ShapeItem], contentFrame: SkinRect) {
        self.sourceID = sourceID
        self.revision = revision
        self.shapes = shapes
        self.contentFrame = contentFrame
    }

    public static func == (lhs: ShapeDraw, rhs: ShapeDraw) -> Bool {
        lhs.sourceID == rhs.sourceID && lhs.revision == rhs.revision && lhs.contentFrame == rhs.contentFrame
    }
}

public extension ShapeMeter {
    /// Capture after layout on the skin's owner. Later parsing, updates and closing the skin leave this value intact.
    func lower() -> ShapeDraw {
        skin.assertOwned()
        return ShapeDraw(sourceID: drawingIdentity, revision: revision, shapes: shapes, contentFrame: contentFrame)
    }
}
