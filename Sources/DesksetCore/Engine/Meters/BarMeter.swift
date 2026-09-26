import Foundation

/// `Meter=Bar` (manual: Meters → Bar): a bar filled to the percentual value of `MeasureName`.
///
/// - `BarColor` (default 0,128,0) fills the content rect; `BarOrientation` Vertical (default, fills bottom → top)
///   or Horizontal (left → right); `Flip=1` reverses the direction.
/// - `BarImage` (+ ImagePath and all general image options) is "revealed" instead: it is drawn at its own size
///   (W/H do not scale it; they only size the meter frame, which defaults to the image size), and the bar is
///   constrained to the image. `BarBorder` pixels at both ends of the image (top/bottom for vertical, left/right
///   for horizontal) are always drawn; the part between them is revealed.
/// - The filled length is truncated to whole pixels (judgment call; Rainmeter bars are pixel aligned).
public final class BarMeter: Meter {
    public private(set) var barColor = RGBA(r: 0, g: 128, b: 0)
    public private(set) var barImagePath: String?
    public private(set) var imageOptions = ImageOptions()
    public private(set) var vertical = true
    public private(set) var flip = false
    public private(set) var barBorder = 0.0
    /// 0…1 fill amount from the first bound measure.
    public private(set) var fraction = 0.0

    public override func readMeterOptions() {
        barColor = color("BarColor", RGBA(r: 0, g: 128, b: 0))
        imageOptions = ImageOptions.read(from: self)
        barImagePath = ImageOptions.filePath(string("BarImage"), imagePath: ImageOptions.imagePathOption(self),
                                             skin: skin)
        vertical = string("BarOrientation", "Vertical").trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("Horizontal") != .orderedSame
        flip = bool("Flip", false)
        let border = double("BarBorder", 0)
        barBorder = border.isFinite ? border.clamped(0, ImageOptions.maxSide) : 0
    }

    public override func updateMeter() {
        let f = (measureSlots.first ?? nil)?.relativeValue ?? 0
        fraction = f.isFinite ? f.clamped(0, 1) : 0
    }

    /// Size of BarImage after crop/rotation (nil without a loadable BarImage).
    public var barImageSize: (width: Double, height: Double)? {
        imageDisplaySize(barImagePath, imageOptions)
    }

    public override func naturalSize() -> (width: Double, height: Double) {
        barImageSize ?? (0, 0)
    }

    /// Where BarImage is drawn: the content origin at the image's own size. Nil without a loadable BarImage.
    public func barImageRect() -> SkinRect? {
        guard barImagePath != nil, let size = barImageSize else { return nil }
        let c = contentFrame
        return SkinRect(x: c.x, y: c.y, width: size.width, height: size.height)
    }

    /// The visible parts of the bar in skin coordinates: one rectangle for BarColor, or (with BarImage) the
    /// revealed part plus the two BarBorder ends, which the renderer uses to clip the image. Empty rectangles
    /// are omitted.
    public func visibleBarRects() -> [SkinRect] {
        if barImagePath != nil {
            guard let area = barImageRect() else { return [] }
            return BarMeter.barRects(area: area, fraction: fraction, vertical: vertical, flip: flip, border: barBorder)
        }
        return BarMeter.barRects(area: contentFrame, fraction: fraction, vertical: vertical, flip: flip, border: 0)
    }

    /// Bar geometry: `border` pixels at each end of `area` along the bar direction are always included; the
    /// remaining length is filled to `fraction` (truncated to whole pixels) from the bottom (vertical) or left
    /// (horizontal), or from the opposite end when `flip`.
    public static func barRects(area: SkinRect, fraction: Double, vertical: Bool, flip: Bool, border: Double)
        -> [SkinRect] {
        guard area.width > 0, area.height > 0 else { return [] }
        let f = fraction.isFinite ? fraction.clamped(0, 1) : 0
        let length = vertical ? area.height : area.width
        let b = min(max(border, 0), length / 2)
        let inner = length - 2 * b
        let filled = (f * inner + 1e-9).rounded(.down).clamped(0, inner)
        var rects: [SkinRect] = []
        if vertical {
            if b > 0 {
                rects.append(SkinRect(x: area.x, y: area.y, width: area.width, height: b))
                rects.append(SkinRect(x: area.x, y: area.maxY - b, width: area.width, height: b))
            }
            if filled > 0 {
                let y = flip ? area.y + b : area.maxY - b - filled
                rects.append(SkinRect(x: area.x, y: y, width: area.width, height: filled))
            }
        } else {
            if b > 0 {
                rects.append(SkinRect(x: area.x, y: area.y, width: b, height: area.height))
                rects.append(SkinRect(x: area.maxX - b, y: area.y, width: b, height: area.height))
            }
            if filled > 0 {
                let x = flip ? area.maxX - b - filled : area.x + b
                rects.append(SkinRect(x: x, y: area.y, width: filled, height: area.height))
            }
        }
        return rects
    }
}
