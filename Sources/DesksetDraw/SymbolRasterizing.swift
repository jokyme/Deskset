import CoreGraphics
import DesksetCore

/// A symbol's raster pixels and natural size in points, before any general image options are applied.
public struct RasterizedSymbol {
    public let image: CGImage
    public let pointSize: CGSize

    public init(image: CGImage, pointSize: CGSize) {
        self.image = image
        self.pointSize = pointSize
    }
}

/// The platform's symbol drawing, kept outside the image cache and drawing layer.
public protocol SymbolRasterizing {
    func render(_ symbol: MacSymbol) -> RasterizedSymbol?
}
