import CoreGraphics
import DesksetCore

/// Desk symbols use native foreground colors and appearance. This capability is separate from the legacy
/// MacSymbol rasterizer, whose white images and ImageTint processing are part of the INI contract.
public protocol IconRasterizing {
    /// A cached size must not hide an evicted asynchronous native resource.
    func isPrepared(_ request: IconRequest, font: ResolvedFont, fontGeneration: Int) -> Bool
    /// Nil means that the operating system has no such symbol; malformed input or allocation failure throws.
    func measure(_ request: IconRequest, font: ResolvedFont, fontGeneration: Int) throws -> SkinSize?
    /// The caller has checked and budgeted these exact pixel dimensions before asking for a native bitmap.
    func rasterize(_ request: IconRequest, font: ResolvedFont, fontGeneration: Int, naturalSize: SkinSize,
                   pixelWidth: Int, pixelHeight: Int) throws -> RasterizedSymbol
}

public extension IconRasterizing {
    func isPrepared(_ request: IconRequest, font: ResolvedFont, fontGeneration: Int) -> Bool { true }
}

public enum IconDrawingError: Error, Equatable {
    case unavailableRasterizer, invalidGeometry, invalidFont, naturalSizeChanged, bitmapBudget, rasterization
}
