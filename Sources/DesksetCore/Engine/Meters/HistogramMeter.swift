import Foundation

/// `Meter=Histogram`: a histogram of the current and past values of one or two measures.
///
/// Manual (docs.rainmeter.net/manual/meters/histogram/):
/// - MeasureName is the primary graph; MeasureName2 (deprecated alias: SecondaryMeasureName) an optional
///   secondary graph. The measures must be able to return percentual values.
/// - AutoScale=1: the histogram is scaled automatically to show all the values.
/// - PrimaryColor (default 0,128,0), SecondaryColor (default 255,0,0), BothColor (default 255,255,0) where the
///   two histograms overlap.
/// - PrimaryImage / SecondaryImage / BothImage replace the colors; the image is "revealed" horizontally and
///   vertically by the value and over time. The image size cannot be changed with W/H: the histogram takes the
///   image's size. Paths: PrimaryImagePath… Image options: PrimaryGreyScale, PrimaryImageCrop, PrimaryImageTint,
///   PrimaryImageAlpha, PrimaryImageFlip (and Secondary…/Both… variants).
/// - GraphStart, GraphOrientation, Flip: see GraphHistory.swift.
///
/// Judgment calls:
/// - Without AutoScale each measure is shown as its own percentage of MinValue…MaxValue (like a Bar meter).
/// - AutoScale=1 uses one common range for both measures: min(smallest MinValue, smallest recorded sample) up to
///   the largest recorded sample, so primary and secondary stay comparable.
/// - Column lengths are rounded to whole pixels unless AntiAlias=1.
/// - Each part (primary-only, secondary-only, overlap) uses its image when one is set and loads, else its color.
///   The histogram's size comes from the first set image (Primary, Secondary, Both) when it loads; a crop's W,H
///   wins. A first image that cannot be loaded leaves W/H in effect.
/// - An image name without extension gets ".png" (General Image Options: ".png is assumed").
/// - PrimaryImageRotate and the ColorMatrix options are not supported (reported as compatibility issues).
public final class HistogramMeter: Meter {
    /// One of PrimaryImage / SecondaryImage / BothImage with its image options.
    public struct HistogramImage: Equatable {
        public var path: String
        /// `ImageCrop=X,Y,W,H[,Origin]`.
        public var crop: [Double]?
        /// Tint color (alpha always 255; opacity is in `alpha`); nil = no tint.
        public var tint: RGBA?
        /// 0…255: ImageAlpha, else the alpha of ImageTint.
        public var alpha: Double
        public var greyscale: Bool
        public var flipHorizontal: Bool
        public var flipVertical: Bool

        /// Crop rectangle in image pixels for an image of the given size (Origin 1 top-left … 4 bottom-left,
        /// 5 center), or nil when there is no usable crop.
        public func cropRect(imageWidth: Double, imageHeight: Double) -> SkinRect? {
            guard let crop, crop.count >= 4, crop.prefix(4).allSatisfy(\.isFinite), crop[2] > 0, crop[3] > 0
            else { return nil }
            let origin = crop.count >= 5 ? Int(crop[4].clamped(0, 10)) : 1
            let (ox, oy): (Double, Double)
            switch origin {
            case 2: (ox, oy) = (imageWidth, 0)
            case 3: (ox, oy) = (imageWidth, imageHeight)
            case 4: (ox, oy) = (0, imageHeight)
            case 5: (ox, oy) = (imageWidth / 2, imageHeight / 2)
            default: (ox, oy) = (0, 0)
            }
            return SkinRect(x: ox + crop[0], y: oy + crop[1], width: crop[2], height: crop[3])
        }
    }

    public enum Part { case primary, secondary, both }

    public private(set) var primaryMeasure: Measure?
    public private(set) var secondaryMeasure: Measure?
    public private(set) var primaryHistory = GraphHistory()
    public private(set) var secondaryHistory = GraphHistory()
    public private(set) var primaryColor = RGBA(r: 0, g: 128, b: 0)
    public private(set) var secondaryColor = RGBA(r: 255, g: 0, b: 0)
    public private(set) var bothColor = RGBA(r: 255, g: 255, b: 0)
    public private(set) var primaryImage: HistogramImage?
    public private(set) var secondaryImage: HistogramImage?
    public private(set) var bothImage: HistogramImage?
    public private(set) var autoScale = false
    public private(set) var direction = GraphDirection()
    /// Samples per history (the time axis in whole pixels).
    public private(set) var historyLength = 0
    /// Common AutoScale range (recomputed on every meter update).
    public private(set) var autoRangeMin = 0.0
    public private(set) var autoRangeMax = 1.0
    /// Size of the image that defines the meter size (nil = W/H apply).
    private var imageSize: (width: Double, height: Double)?

    public var hasSecondary: Bool { secondaryMeasure != nil }

    public override func readMeterOptions() {
        primaryMeasure = measure(forOption: "MeasureName")
        let secondaryName = option("MeasureName2").map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        secondaryMeasure = measure(forOption: secondaryName.isEmpty ? "SecondaryMeasureName" : "MeasureName2")

        primaryColor = color("PrimaryColor", RGBA(r: 0, g: 128, b: 0))
        secondaryColor = color("SecondaryColor", RGBA(r: 255, g: 0, b: 0))
        bothColor = color("BothColor", RGBA(r: 255, g: 255, b: 0))
        primaryImage = readImage("Primary")
        secondaryImage = readImage("Secondary")
        bothImage = readImage("Both")
        autoScale = bool("AutoScale", false)
        direction = GraphDirection.read(from: self)

        imageSize = nil
        for image in [primaryImage, secondaryImage, bothImage] {
            guard let image else { continue }
            // Only an image that loads defines the size (a crop of a missing file must not: the parts are then
            // drawn with their colors, in W×H like any histogram without images).
            if let size = skin.host?.imageSize(atPath: image.path) {
                if let crop = image.crop, crop.count >= 4, crop[2] > 0, crop[3] > 0,
                   crop[2].isFinite, crop[3].isFinite {
                    imageSize = (crop[2], crop[3])
                } else {
                    imageSize = size
                }
            }
            break
        }
        if imageSize != nil {
            // "The image size cannot be modified with the W or H general meter options": layout uses naturalSize.
            widthOption = nil
            heightOption = nil
        }
    }

    private func measure(forOption key: String) -> Measure? {
        let name = string(key).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let m = skin.measure(named: name) { return m }
        if key.caseInsensitiveCompare("SecondaryMeasureName") == .orderedSame {
            skin.log("[\(self.name)] SecondaryMeasureName=\(name) not found", level: .warning)
        }
        return nil
    }

    private func readImage(_ prefix: String) -> HistogramImage? {
        // Windows skins write `Images\Graph`: check the extension of the last path component only.
        var name = string("\(prefix)Image").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\", with: "/")
        guard !name.isEmpty else { return nil }
        if (name as NSString).pathExtension.isEmpty { name += ".png" }
        let path = skin.imageFilePath(name, imagePath: string("\(prefix)ImagePath"))
        let crop = OptionValue.numbers(string("\(prefix)ImageCrop"))
        var tint = option("\(prefix)ImageTint").flatMap(OptionValue.color)
        let alpha = (optionalDouble("\(prefix)ImageAlpha") ?? tint?.a ?? 255).clamped(0, 255)
        tint?.a = 255
        if tint == RGBA.white { tint = nil }
        let flip = string("\(prefix)ImageFlip", "None").trimmingCharacters(in: .whitespaces).lowercased()
        if double("\(prefix)ImageRotate", 0) != 0 {
            skin.addIssue("Histogram \(prefix)ImageRotate is not supported")
        }
        // ColorMatrix1…5 are separate rows; a skin may set only one of them (e.g. ColorMatrix5 for offsets).
        if (1...5).contains(where: { option("\(prefix)ColorMatrix\($0)") != nil
                                     || option("\(prefix)ImageColorMatrix\($0)") != nil }) {
            skin.addIssue("Histogram \(prefix) ColorMatrix options are not supported")
        }
        return HistogramImage(path: path, crop: crop.count >= 4 ? crop : nil, tint: tint, alpha: alpha,
                              greyscale: bool("\(prefix)GreyScale", false),
                              flipHorizontal: flip == "horizontal" || flip == "both",
                              flipVertical: flip == "vertical" || flip == "both")
    }

    public override func naturalSize() -> (width: Double, height: Double) {
        imageSize ?? (0, 0)
    }

    /// Adds one sample per measure, resizing the histories first when the size changed.
    public override func updateMeter() {
        let length = imageSize.map { direction.vertical ? $0.width : $0.height }
            ?? (direction.vertical ? widthOption : heightOption)
        historyLength = GraphHistory.capacity(forLength: length)
        primaryHistory.resize(to: historyLength)
        secondaryHistory.resize(to: historyLength)
        primaryHistory.append(primaryMeasure?.value ?? 0)
        secondaryHistory.append(secondaryMeasure?.value ?? 0)
        computeAutoRange()
    }

    private func computeAutoRange() {
        var lo = Double.infinity, hi = -Double.infinity
        for (measure, history) in [(primaryMeasure, primaryHistory), (secondaryMeasure, secondaryHistory)] {
            guard let measure else { continue }
            lo = min(lo, measure.minValue)
            if let e = history.extremes {
                lo = min(lo, e.min)
                hi = max(hi, e.max)
            }
        }
        if lo == .infinity { lo = 0 }
        if hi == -.infinity { hi = lo }
        (autoRangeMin, autoRangeMax) = GraphRange.normalized(lo, hi)
    }

    /// Primary (or secondary) value `age` samples ago mapped to 0…1.
    public func fraction(secondary: Bool = false, age: Int) -> Double {
        guard let measure = secondary ? secondaryMeasure : primaryMeasure else { return 0 }
        let v = (secondary ? secondaryHistory : primaryHistory).value(age: age)
        if autoScale { return GraphRange.fraction(v, autoRangeMin, autoRangeMax) }
        return GraphRange.fraction(v, measure.minValue, measure.maxValue)
    }

    /// Geometry of the current content frame.
    public var geometry: GraphGeometry { GraphGeometry(frame: contentFrame, direction: direction) }

    /// Column lengths in points from the baseline (whole pixels unless AntiAlias=1).
    public func columnLengths(age: Int) -> (primary: Double, secondary: Double) {
        let length = geometry.valueLength
        func size(_ f: Double) -> Double {
            let v = f * length
            return antiAlias ? v : v.rounded()
        }
        return (size(fraction(age: age)), hasSecondary ? size(fraction(secondary: true, age: age)) : 0)
    }

    /// The three parts of the column `age` in skin coordinates; a part that is not drawn has zero length.
    /// With one measure only `primary` is used; with two, the overlap is `both` and the longer one's excess is
    /// `primary` or `secondary`.
    public func columnRects(age: Int) -> (primary: SkinRect, secondary: SkinRect, both: SkinRect) {
        let g = geometry
        let (p, s) = columnLengths(age: age)
        let empty = g.column(age: age, from: 0, to: 0)
        guard hasSecondary else { return (g.column(age: age, from: 0, to: p), empty, empty) }
        let common = min(p, s)
        return (p > common ? g.column(age: age, from: common, to: p) : empty,
                s > common ? g.column(age: age, from: common, to: s) : empty,
                common > 0 ? g.column(age: age, from: 0, to: common) : empty)
    }
}
