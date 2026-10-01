import Foundation

/// The numeric part of Rainmeter meter layout. Inputs are read on the owner at each placement, after that meter's
/// update and actions; in particular, `previous` is its current geometry, not a kept result from an earlier pass.
/// Resource measurement and committing a frame belong to the caller.
enum RainmeterLayout {
    struct Output: Equatable, Sendable {
        let frame: SkinRect
        let anchor: SkinPoint
    }

    struct Input: Equatable, Sendable {
        let x: PositionValue
        let y: PositionValue
        let size: SkinSize
        let origin: SkinPoint
        let previous: Output?
        let alignShift: SkinPoint
        let hidden: Bool
    }

    /// One visible content dimension, including padding. A hidden meter skips measurement and uses zero instead.
    static func dimension(option: Double?, natural: Double, leading: Double, trailing: Double) -> Double {
        let content = option ?? finite(natural)
        let result = finite(content + leading + trailing).clamped(0, Meter.maxCoordinate)
        #if DEBUG
        // The original Meter.layout expression, on the same captured values and without another resource query.
        let reference = referenceFinite((option ?? referenceFinite(natural)) + leading + trailing).clamped(0, Meter.maxCoordinate)
        assert(result == reference, "Rainmeter layout dimension differs from the original expression")
        #endif
        return result
    }

    static func place(_ input: Input) -> Output {
        let x = resolve(input.x, origin: input.origin.x, start: input.previous?.anchor.x,
                        end: input.previous.map { $0.anchor.x + $0.frame.width })
        let y = resolve(input.y, origin: input.origin.y, start: input.previous?.anchor.y,
                        end: input.previous.map { $0.anchor.y + $0.frame.height })
        let output = Output(
            frame: SkinRect(x: finite(x + (input.hidden ? 0 : input.alignShift.x)),
                            y: finite(y + (input.hidden ? 0 : input.alignShift.y)),
                            width: input.size.width, height: input.size.height),
            anchor: SkinPoint(x: finite(x), y: finite(y)))
        #if DEBUG
        assert(output == referencePlacement(input), "Rainmeter layout placement differs from the original expression")
        #endif
        return output
    }

    private static func resolve(_ position: PositionValue, origin: Double, start: Double?, end: Double?) -> Double {
        switch position.mode {
        case .absolute: return origin + position.value
        case .relativeToPreviousStart: return (start ?? origin) + position.value
        case .relativeToPreviousEnd: return (end ?? start ?? origin) + position.value
        }
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value.clamped(-Meter.maxCoordinate, Meter.maxCoordinate) : 0
    }

    /// A window grows only to the right and below the origin. Callers pass visible, non-content frames.
    static func extentFromOrigin<Frames: Sequence>(_ frames: Frames) -> SkinSize where Frames.Element == SkinRect {
        var w = 0.0, h = 0.0
        for frame in frames {
            w = max(w, frame.maxX)
            h = max(h, frame.maxY)
        }
        return SkinSize(width: w, height: h)
    }

    static func windowSize(extent: SkinSize, background: SkinSize?, fixedWidth: Double?, fixedHeight: Double?)
        -> SkinSize {
        var w = extent.width, h = extent.height
        if let background {
            w = max(w, background.width)
            h = max(h, background.height)
        }
        return SkinSize(width: side(fixedWidth ?? w), height: side(fixedHeight ?? h))
    }

    /// Unlike window sizing, the editor's bounds include content left of and above the origin.
    static func contentBounds(_ frames: [SkinRect], background: SkinSize?) -> SkinRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ x: Double, _ y: Double, _ right: Double, _ bottom: Double) {
            guard x.isFinite, y.isFinite, right.isFinite, bottom.isFinite else { return }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, right)
            maxY = max(maxY, bottom)
        }
        for frame in frames { add(frame.x, frame.y, frame.maxX, frame.maxY) }
        if let background { add(0, 0, background.width, background.height) }
        guard minX <= maxX, minY <= maxY else { return SkinRect() }
        return SkinRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func side(_ value: Double) -> Double {
        value.isFinite ? value.clamped(1, Skin.maxSide) : 1
    }

    #if DEBUG
    /// The old Meter.layout arithmetic after measurement and before its three assignments. It takes exactly the
    /// same captured inputs: shadowing must neither query the host twice nor commit another frame/generation.
    private static func referencePlacement(_ input: Input) -> Output {
        func resolve(_ p: PositionValue, origin: Double, start: Double?, end: Double?) -> Double {
            switch p.mode {
            case .absolute: return origin + p.value
            case .relativeToPreviousStart: return (start ?? origin) + p.value
            case .relativeToPreviousEnd: return (end ?? start ?? origin) + p.value
            }
        }
        let x = resolve(input.x, origin: input.origin.x, start: input.previous?.anchor.x,
                        end: input.previous.map { $0.anchor.x + $0.frame.width })
        let y = resolve(input.y, origin: input.origin.y, start: input.previous?.anchor.y,
                        end: input.previous.map { $0.anchor.y + $0.frame.height })
        let anchorX = referenceFinite(x)
        let anchorY = referenceFinite(y)
        let frame = SkinRect(x: referenceFinite(x + (input.hidden ? 0 : input.alignShift.x)),
                             y: referenceFinite(y + (input.hidden ? 0 : input.alignShift.y)),
                             width: input.size.width, height: input.size.height)
        return Output(frame: frame, anchor: SkinPoint(x: anchorX, y: anchorY))
    }
    private static func referenceFinite(_ v: Double) -> Double {
        v.isFinite ? v.clamped(-Meter.maxCoordinate, Meter.maxCoordinate) : 0
    }
    #endif
}
