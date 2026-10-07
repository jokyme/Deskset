/// A Roundline's geometry and paint for one frame, independent of its meter and measure.
public struct RoundlineDraw: Equatable, Sendable {
    public var shape: RoundlineMeter.Shape
    public var color: RGBA
    public var antiAlias: Bool
    /// Opt-in rounded ends for radial progress. INI lowering keeps its original flat line/sector contract.
    public var roundCaps: Bool

    public init(shape: RoundlineMeter.Shape, color: RGBA, antiAlias: Bool, roundCaps: Bool = false) {
        self.shape = shape
        self.color = color
        self.antiAlias = antiAlias
        self.roundCaps = roundCaps
    }
}

/// A Rotator's resolved image options and placement for one frame. Decoding and processed-image caches belong
/// to the renderer; no live meter or measure is needed to draw this value.
public struct RotatorDraw: Equatable, Sendable {
    public var path: String?
    public var processing: RotatorMeter.ImageProcessing
    public var transform: RoundMeterMath.Transform

    public init(path: String?, processing: RotatorMeter.ImageProcessing, transform: RoundMeterMath.Transform) {
        self.path = path
        self.processing = processing
        self.transform = transform
    }
}

public extension RoundlineMeter {
    /// Captures the current drawing after layout, on the skin's owner.
    func lower() -> RoundlineDraw {
        skin.assertOwned()
        return RoundlineDraw(shape: shape, color: lineColor, antiAlias: antiAlias)
    }
}

public extension RotatorMeter {
    /// Captures the current drawing after layout, on the skin's owner.
    func lower() -> RotatorDraw {
        skin.assertOwned()
        return RotatorDraw(path: imagePath, processing: imageProcessing, transform: imageTransform)
    }
}
