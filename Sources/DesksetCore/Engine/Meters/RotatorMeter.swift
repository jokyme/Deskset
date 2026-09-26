import Foundation

/// `Meter=Rotator`: an image that rotates around a point with a measure value
/// (docs.rainmeter.net/manual/meters/rotator/; angle math in `RoundMeterMath`).
///
/// - The center of rotation is the middle of W×H; without W/H the meter has no size and the center is at X/Y
///   (manual Remarks). The image is drawn at its own pixel size — W/H only place the center — and is not clipped
///   to the meter box (without W/H the box is empty, yet the image shows until the skin window cuts it off).
/// - `OffsetX`/`OffsetY` are the image point that sits on the center of rotation (the manual's "Rotate an Image
///   Around its Center" tip sets them to half the image size).
/// - "All general image options are valid for ImageName": ImagePath, ImageCrop (with Origin), Greyscale,
///   ImageTint, ImageAlpha, ImageFlip, ImageRotate and ColorMatrix1…5 are applied to the image before it is
///   rotated (the renderer caches the result). UseExifOrientation=1 turns the image upright first.
public final class RotatorMeter: Meter {
    /// Image processing requested by the general image options, applied once to the decoded image.
    public struct ImageProcessing: Hashable {
        /// `ImageCrop=X,Y,W,H[,Origin]` resolved to a rectangle relative to the image's top-left corner given
        /// the image size — see `Crop.rect(imageWidth:imageHeight:)`.
        public var crop: Crop?
        public var flipHorizontal = false
        public var flipVertical = false
        /// `ImageRotate`, degrees, positive clockwise.
        public var rotateDegrees = 0.0
        /// 5×5 color matrix, row-major, row-vector convention (`[r g b a 1] × M`, components 0…1; row 5 holds
        /// offsets), or nil for "unchanged". Built from Greyscale / ImageTint / ImageAlpha or ColorMatrixN.
        public var colorMatrix: [Double]?
        /// `UseExifOrientation=1`: the renderer turns the file image upright by its EXIF orientation before the
        /// other options (default 0: the pixels as stored, as the manual says).
        public var useExifOrientation = false

        public init() {}

        /// True when the image can be drawn as decoded.
        public var isIdentity: Bool {
            crop == nil && !flipHorizontal && !flipVertical && rotateDegrees == 0 && colorMatrix == nil
        }

        /// This processing with a plain opacity factor taken out of `colorMatrix`, and that factor (0…1).
        ///
        /// ImageAlpha, the ImageTint alpha, or a ColorMatrix whose only alpha term is a 0…1 scale of the alpha
        /// just scale the opacity: `out_a = a·s` and no color depends on `a`. Drawing the rest with a global
        /// alpha of `s` gives the same pixels, so the renderer caches the processed image without that factor
        /// and applies it while drawing. A fade (ImageAlpha changing on every update) then reuses one cached
        /// image instead of re-processing the whole bitmap each frame.
        public var opacitySplit: (processing: ImageProcessing, opacity: Double) {
            guard let m = colorMatrix, m.count == 25 else { return (self, 1) }
            let s = m[18]
            guard s >= 0, s <= 1, m[3] == 0, m[8] == 0, m[13] == 0, m[23] == 0,
                  m[15] == 0, m[16] == 0, m[17] == 0 else { return (self, 1) }
            var rest = self
            var baked = m
            baked[18] = 1
            rest.colorMatrix = baked == RotatorMeter.identityMatrix ? nil : baked
            return (rest, s)
        }
    }

    /// `ImageCrop` values; `origin` 1 top-left (default), 2 top-right, 3 bottom-right, 4 bottom-left, 5 center.
    public struct Crop: Hashable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var origin: Int

        public init(x: Double, y: Double, width: Double, height: Double, origin: Int = 1) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.origin = origin
        }

        /// Crop rectangle relative to the image's top-left corner: X/Y are measured from `origin` ("negative
        /// number is left … negative number is up"). The rectangle may extend past the image; the renderer
        /// leaves that part transparent (judgment call — the manual does not say).
        public func rect(imageWidth: Double, imageHeight: Double) -> SkinRect {
            let ox: Double, oy: Double
            switch origin {
            case 2: (ox, oy) = (imageWidth, 0)
            case 3: (ox, oy) = (imageWidth, imageHeight)
            case 4: (ox, oy) = (0, imageHeight)
            case 5: (ox, oy) = (imageWidth / 2, imageHeight / 2)
            default: (ox, oy) = (0, 0)
            }
            return SkinRect(x: ox + x, y: oy + y, width: width, height: height)
        }
    }

    /// Largest processed image side we allow (crop / rotation canvases).
    public static let maxImageSide = 8192.0

    /// Absolute path of the image (nil = nothing to draw).
    public private(set) var imagePath: String?
    public private(set) var imageProcessing = ImageProcessing()
    public private(set) var offsetX = 0.0
    public private(set) var offsetY = 0.0
    public private(set) var startAngle = 0.0
    public private(set) var rotationAngle = RoundMeterMath.fullCircle
    public private(set) var valueRemainder = 0.0
    /// 0…1 rotation fraction from the bound measure (1 without one, as for Roundline — the Rotator page is
    /// silent; with the default RotationAngle of 2π that looks the same as 0).
    public private(set) var fraction = 1.0

    /// Current rotation in radians.
    public var angle: Double {
        RoundMeterMath.angle(startAngle: startAngle, rotationAngle: rotationAngle, fraction: fraction)
    }

    /// Center of rotation in skin coordinates.
    public var center: (x: Double, y: Double) { RoundMeterMath.center(of: contentFrame) }

    /// Maps processed-image pixel coordinates (top-left origin) to skin coordinates.
    public var imageTransform: RoundMeterMath.Transform {
        let c = center
        return RoundMeterMath.rotatorTransform(centerX: c.x, centerY: c.y, angle: angle,
                                               offsetX: offsetX, offsetY: offsetY)
    }

    public override func readMeterOptions() {
        let name = string("ImageName").trimmingCharacters(in: .whitespaces)
        imagePath = name.isEmpty ? nil : Self.withDefaultExtension(skin.imageFilePath(name, imagePath: string("ImagePath")))
        offsetX = RoundMeterMath.extent(double("OffsetX", 0))
        offsetY = RoundMeterMath.extent(double("OffsetY", 0))
        startAngle = finite(double("StartAngle", 0), 0)
        rotationAngle = finite(double("RotationAngle", RoundMeterMath.fullCircle), RoundMeterMath.fullCircle)
        valueRemainder = finite(double("ValueRemainder", 0), 0)
        imageProcessing = readImageProcessing()
        updateFraction()
    }

    public override func updateMeter() {
        updateFraction()
    }

    private func updateFraction() {
        guard let m = measureSlots.first ?? nil else {
            fraction = 1
            return
        }
        fraction = RoundMeterMath.fraction(value: m.value, minValue: m.minValue, maxValue: m.maxValue,
                                           valueRemainder: valueRemainder)
    }

    // MARK: General image options

    private func readImageProcessing() -> ImageProcessing {
        var p = ImageProcessing()
        let crop = OptionValue.numbers(string("ImageCrop"))
        if crop.count >= 4, crop[2] > 0, crop[3] > 0, crop.prefix(4).allSatisfy({ $0.isFinite }) {
            let origin = crop.count >= 5 && crop[4].isFinite ? Int(crop[4].clamped(1, 5)) : 1
            p.crop = Crop(x: RoundMeterMath.extent(crop[0]), y: RoundMeterMath.extent(crop[1]),
                          width: min(crop[2], Self.maxImageSide), height: min(crop[3], Self.maxImageSide),
                          origin: origin)
        }
        switch string("ImageFlip", "None").trimmingCharacters(in: .whitespaces).lowercased() {
        case "horizontal": p.flipHorizontal = true
        case "vertical": p.flipVertical = true
        case "both": p.flipHorizontal = true; p.flipVertical = true
        default: break
        }
        let rotate = double("ImageRotate", 0)
        p.rotateDegrees = rotate.isFinite ? fmod(rotate, 360) : 0
        p.useExifOrientation = bool("UseExifOrientation", false)
        p.colorMatrix = Self.colorMatrix(greyscale: bool("Greyscale", false),
                                         tint: color("ImageTint", .white),
                                         alpha: optionalDouble("ImageAlpha"),
                                         matrixRows: (1...5).map { option("ColorMatrix\($0)") })
        return p
    }

    /// Effective color matrix for the general image options, or nil when the image is unchanged.
    ///
    /// Manual (General Image Options): Greyscale desaturates; ImageTint (default opaque white) tints — "Combining
    /// Greyscale and ImageTint recolors the image to the specified color"; ImageAlpha (0…255) "overrides the alpha
    /// component specified in ImageTint"; ColorMatrix1…5 (rows of `a; b; c; d; e`, identity by default, row 5 =
    /// offsets) "overrides ImageTint and ImageAlpha". Judgment calls: tint multiplies each channel by
    /// tint/255 (same as the Image meter); greyscale uses Rec. 601 luma weights and is applied before the tint or
    /// the custom matrix; missing / short ColorMatrix rows keep their identity values.
    public static func colorMatrix(greyscale: Bool, tint: RGBA, alpha: Double?,
                                   matrixRows: [String?]) -> [Double]? {
        var m = identityMatrix
        if greyscale {
            let weights = [0.299, 0.587, 0.114]
            var g = identityMatrix
            for i in 0..<3 {
                for j in 0..<3 { g[i * 5 + j] = weights[i] }
            }
            m = g
        }
        if matrixRows.contains(where: { $0 != nil }) {
            var custom = identityMatrix
            for (row, text) in matrixRows.prefix(5).enumerated() {
                guard let text else { continue }
                let values = OptionValue.numbers(text, separator: ";")
                for (col, v) in values.prefix(5).enumerated() where v.isFinite {
                    custom[row * 5 + col] = RoundMeterMath.extent(v)
                }
            }
            m = multiply(m, custom)
        } else {
            let a = (alpha ?? tint.a).clamped(0, 255) / 255
            var t = identityMatrix
            t[0] = tint.r.clamped(0, 255) / 255
            t[6] = tint.g.clamped(0, 255) / 255
            t[12] = tint.b.clamped(0, 255) / 255
            t[18] = a
            m = multiply(m, t)
        }
        return m == identityMatrix ? nil : m
    }

    public static let identityMatrix: [Double] = (0..<25).map { $0 % 6 == 0 ? 1 : 0 }

    /// 5×5 row-major product `x × y` (apply `x` first, then `y`, in the row-vector convention).
    static func multiply(_ x: [Double], _ y: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 25)
        for i in 0..<5 {
            for j in 0..<5 {
                var s = 0.0
                for k in 0..<5 { s += x[i * 5 + k] * y[k * 5 + j] }
                r[i * 5 + j] = s
            }
        }
        return r
    }

    /// "If no file extension is included, .png is assumed" (General Image Options). A file that exists as
    /// written is used as is.
    static func withDefaultExtension(_ path: String) -> String {
        guard (path as NSString).pathExtension.isEmpty, !path.hasSuffix("/"),
              !FileManager.default.fileExists(atPath: path) else { return path }
        return path + ".png"
    }

    private func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
}
