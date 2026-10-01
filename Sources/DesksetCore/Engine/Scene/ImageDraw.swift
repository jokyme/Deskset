/// An Image meter's resolved source, processing and placement for one frame. Image loading and drawing caches
/// remain with the renderer; the value does not retain the skin, meter or its image queries.
public struct ImageDraw: Equatable, Sendable {
    public var contentFrame: SkinRect
    public var path: String?
    public var options: ImageOptions
    public var maskPath: String?
    public var maskOptions: ImageOptions
    public var preserveAspectRatio: Int
    public var tile: Bool
    public var scaleMargins: SkinInsets?
    public var decodesAtDrawnSize: Bool

    public init(contentFrame: SkinRect, path: String?, options: ImageOptions, maskPath: String?,
                maskOptions: ImageOptions, preserveAspectRatio: Int, tile: Bool, scaleMargins: SkinInsets?,
                decodesAtDrawnSize: Bool) {
        self.contentFrame = contentFrame
        self.path = path
        self.options = options
        self.maskPath = maskPath
        self.maskOptions = maskOptions
        self.preserveAspectRatio = preserveAspectRatio
        self.tile = tile
        self.scaleMargins = scaleMargins
        self.decodesAtDrawnSize = decodesAtDrawnSize
    }
}

/// A Bar's revealed rectangles and optional image placement. Image dimensions have already been read on the
/// skin's owner, so drawing does not need its host or its bound measure.
public struct BarDraw: Equatable, Sendable {
    public var visibleRects: [SkinRect]
    public var imageRect: SkinRect?
    public var path: String?
    public var options: ImageOptions
    public var color: RGBA

    public init(visibleRects: [SkinRect], imageRect: SkinRect?, path: String?, options: ImageOptions, color: RGBA) {
        self.visibleRects = visibleRects
        self.imageRect = imageRect
        self.path = path
        self.options = options
        self.color = color
    }
}

public extension ImageMeter {
    /// Captures the current drawing after layout, on the skin's owner.
    func lower() -> ImageDraw {
        skin.assertOwned()
        return ImageDraw(contentFrame: contentFrame, path: imagePath, options: imageOptions,
                         maskPath: maskImagePath, maskOptions: maskOptions, preserveAspectRatio: preserveAspectRatio,
                         tile: tile, scaleMargins: scaleMargins, decodesAtDrawnSize: decodesAtDrawnSize)
    }
}

public extension BarMeter {
    /// Captures the current drawing after layout, including image-size queries on the skin's owner.
    func lower() -> BarDraw {
        skin.assertOwned()
        let rects = visibleBarRects()
        let imageRect = !rects.isEmpty && barImagePath != nil ? barImageRect() : nil
        return BarDraw(visibleRects: rects, imageRect: imageRect, path: barImagePath, options: imageOptions,
                       color: barColor)
    }
}
