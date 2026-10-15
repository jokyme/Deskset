/// Frames of a strip image, already selected and placed on the skin's owner. Image preparation and drawing
/// caches are renderer state; this value has no button, transition timer, measure or image-query service.
public struct SpriteDraw: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public var source: SkinRect
        public var destination: SkinRect

        public init(source: SkinRect, destination: SkinRect) {
            self.source = source
            self.destination = destination
        }
    }

    public var path: String?
    public var options: ImageOptions
    public var cells: [Cell]
    /// Additional opacity, independent of the image's own alpha (a pressed SF Symbol uses 0.5).
    public var opacity: Double

    public init(path: String?, options: ImageOptions, cells: [Cell], opacity: Double = 1) {
        self.path = path
        self.options = options
        self.cells = cells
        self.opacity = opacity
    }
}

public extension ButtonMeter {
    /// Resolve the strip geometry once while the skin and its image-query service are available.
    func lower() -> SpriteDraw {
        skin.assertOwned()
        let opacity = isSymbol && state == .pressed ? 0.5 : 1.0
        guard let layout = frameLayout, layout.width > 0, layout.height > 0 else {
            return SpriteDraw(path: buttonImagePath, options: imageOptions, cells: [], opacity: opacity)
        }
        let source = ImageGeometry.stripFrameRect(index: isSymbol ? 0 : state.rawValue,
                                                 frameWidth: layout.width, frameHeight: layout.height,
                                                 horizontal: layout.horizontal)
        let content = contentFrame
        let destination = SkinRect(x: content.x, y: content.y, width: layout.width, height: layout.height)
        return SpriteDraw(path: buttonImagePath, options: imageOptions,
                          cells: [.init(source: source, destination: destination)], opacity: opacity)
    }
}

public extension BitmapMeter {
    /// Capture the displayed frames, including the current transition frame, before the next update can change them.
    func lower() -> SpriteDraw {
        skin.assertOwned()
        return SpriteDraw(path: bitmapImagePath, options: imageOptions,
                          cells: cells().map { .init(source: $0.source, destination: $0.destination) })
    }
}
