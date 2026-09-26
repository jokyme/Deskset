import Foundation

/// General image options shared by every meter that draws an image file (manual: Meters → General Options →
/// Image Options): `ImagePath`, `ImageCrop`, `Greyscale`, `ImageTint`, `ImageAlpha`, `ImageFlip`, `ImageRotate`,
/// `UseExifOrientation` and `ColorMatrix1`…`ColorMatrix5`.
///
/// Image, Bar, Bitmap and Button meters read them unprefixed; Histogram reads them with a `Primary` / `Secondary`
/// / `Both` prefix (`PrimaryImageTint`…), which `read(from:prefix:)` supports.
///
/// Pipeline (what the app renders, and what `displaySize` measures):
/// 1. the file is decoded (`.png` assumed when the name has no extension, see `filePath`);
/// 2. `UseExifOrientation=1` applies the EXIF orientation;
/// 3. `ImageCrop` cuts out its rectangle (areas outside the image are transparent);
/// 4. colors are transformed (Greyscale, ImageTint, or ColorMatrix);
/// 5. `ImageFlip`, then `ImageRotate` (clockwise; the result is the rotated bounding box);
/// 6. the meter scales the result to W/H (PreserveAspectRatio, ScaleMargins, Tile) and draws it with `drawAlpha`.
///
/// Judgment calls where the manual is silent: flip is applied before rotation (so the rotation happens on screen,
/// in the direction written); crop and rotate happen after the EXIF orientation.
public struct ImageOptions: Hashable {
    public enum Flip: Hashable {
        case none, horizontal, vertical, both

        public var horizontal: Bool { self == .horizontal || self == .both }
        public var vertical: Bool { self == .vertical || self == .both }

        /// `None` / `Horizontal` / `Vertical` / `Both` (case-insensitive; anything else is `none`).
        public static func parse(_ s: String) -> Flip {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "horizontal": return .horizontal
            case "vertical": return .vertical
            case "both": return .both
            default: return .none
            }
        }
    }

    /// `ImageCrop=X, Y, W, H, Origin`.
    public struct Crop: Hashable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// 1 top left (default), 2 top right, 3 bottom right, 4 bottom left, 5 center.
        public var origin: Int

        public init(x: Double, y: Double, width: Double, height: Double, origin: Int = 1) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.origin = origin
        }

        /// The crop rectangle in pixels of an image of the given size: start at `origin`, move by X/Y (negative
        /// is left/up), take W×H. Values are rounded to whole pixels; W/H are clamped to 0…`ImageOptions.maxSide`.
        public func rect(imageWidth iw: Double, imageHeight ih: Double) -> SkinRect {
            let ox: Double, oy: Double
            switch origin {
            case 2: ox = iw; oy = 0
            case 3: ox = iw; oy = ih
            case 4: ox = 0; oy = ih
            case 5: ox = (iw / 2).rounded(.down); oy = (ih / 2).rounded(.down)
            default: ox = 0; oy = 0
            }
            let lim = ImageOptions.maxSide
            return SkinRect(x: (ox + x).clamped(-lim, lim).rounded(), y: (oy + y).clamped(-lim, lim).rounded(),
                            width: width.clamped(0, lim).rounded(), height: height.clamped(0, lim).rounded())
        }
    }

    /// Largest width/height (pixels) the engine accepts for crops and derived sizes; guards against absurd values.
    public static let maxSide = 32_768.0

    public var crop: Crop?
    public var greyscale = false
    /// `ImageTint` (default opaque white = unchanged).
    public var tint = RGBA.white
    /// `ImageAlpha` when set; it overrides the alpha of `ImageTint`.
    public var alpha: Double?
    /// `ColorMatrix1`…`5` as 25 row-major values, or nil when no ColorMatrix option is set.
    public var colorMatrix: [Double]?
    public var flip = Flip.none
    /// Degrees, clockwise (negative = counter-clockwise).
    public var rotate = 0.0
    public var useExifOrientation = false

    public init() {}

    // MARK: Reading

    /// Reads the image options of `section`. `prefix` is prepended to every option name (`Primary` →
    /// `PrimaryImageCrop`); `colorMatrixKey` overrides the ColorMatrix option stem (Histogram's `BothImageColorMatrix`).
    /// Meters for which the manual excludes ImageCrop / ImageRotate (Bitmap, Button) pass `crop: false` /
    /// `rotate: false`.
    public static func read(from section: SkinSection, prefix: String = "", colorMatrixKey: String? = nil,
                            crop allowCrop: Bool = true, rotate allowRotate: Bool = true) -> ImageOptions {
        var o = ImageOptions()
        if allowCrop {
            let c = OptionValue.numbers(section.string(prefix + "ImageCrop"))
            if c.count >= 4 {
                // Origin is 1…5; anything else (0, 9, garbage) is the default 1, not the nearest valid origin.
                let origin = c.count >= 5 && c[4] >= 1 && c[4] < 6 ? Int(c[4]) : 1
                o.crop = Crop(x: c[0].isFinite ? c[0] : 0, y: c[1].isFinite ? c[1] : 0,
                              width: c[2].isFinite ? c[2] : 0, height: c[3].isFinite ? c[3] : 0, origin: origin)
            }
        }
        o.greyscale = section.bool(prefix + "Greyscale", false)
        o.tint = section.color(prefix + "ImageTint", .white)
        o.alpha = section.optionalDouble(prefix + "ImageAlpha").map { $0.clamped(0, 255) }
        o.flip = Flip.parse(section.string(prefix + "ImageFlip", "None"))
        if allowRotate {
            let r = section.double(prefix + "ImageRotate", 0)
            o.rotate = r.isFinite ? r.truncatingRemainder(dividingBy: 360) : 0
        }
        o.useExifOrientation = section.bool(prefix + "UseExifOrientation", false)
        o.colorMatrix = readColorMatrix(section, stem: colorMatrixKey ?? prefix + "ColorMatrix")
        return o
    }

    /// ColorMatrix rows: `ColorMatrixN=a; b; c; d; e` (values may be formulas). Rows that are not set keep the
    /// identity row; missing trailing values in a row keep the identity values (judgment call). Nil when no row
    /// is set at all.
    static func readColorMatrix(_ section: SkinSection, stem: String) -> [Double]? {
        var m = identityMatrix
        var any = false
        for row in 0..<5 {
            guard let s = section.option("\(stem)\(row + 1)"), !s.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            any = true
            for (col, v) in OptionValue.numbers(s, separator: ";").prefix(5).enumerated() {
                m[row * 5 + col] = v.isFinite ? v.clamped(-1e6, 1e6) : 0
            }
        }
        return any ? m : nil
    }

    /// Raw `ImagePath` option (with `prefix`), "" when not set.
    public static func imagePathOption(_ section: SkinSection, prefix: String = "") -> String {
        section.string(prefix + "ImagePath").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Files

    /// Extensions the manual lists as supported (plus common spellings).
    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "jpe", "bmp", "dib", "gif", "tif",
                                                          "tiff", "webp", "ico", "heic"]

    /// Absolute path of an image file named `name` (relative names resolve against `imagePath`, then the skin
    /// folder; `\` becomes `/`). "If no file extension is included, .png is assumed": `Skin.imageFilePath` adds
    /// `.png` to a name without an extension unless a file of exactly that name exists (that file is used as is).
    /// A name with some other, non-image extension (a measure value such as `12.5`, or `sunny.day`) also gets
    /// `.png` unless a file with the exact name exists. Nil for an empty name.
    public static func filePath(_ name: String, imagePath: String, skin: Skin) -> String? {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.count >= 2, n.hasPrefix("\""), n.hasSuffix("\"") { n = String(n.dropFirst().dropLast()) }
        guard !n.isEmpty else { return nil }
        let path = skin.imageFilePath(n, imagePath: imagePath)
        let last = (path as NSString).lastPathComponent
        let ext = (last as NSString).pathExtension.lowercased()
        // No extension left: an existing extensionless file, or a folder name ending in a separator.
        if ext.isEmpty || supportedExtensions.contains(ext) { return path }
        return FileManager.default.fileExists(atPath: path) ? path : path + ".png"
    }

    // MARK: Colors

    /// Row-major 5×5 identity (rows = input R, G, B, A, offset; columns = output R, G, B, A, placeholder).
    public static let identityMatrix: [Double] = [1, 0, 0, 0, 0,
                                                  0, 1, 0, 0, 0,
                                                  0, 0, 1, 0, 0,
                                                  0, 0, 0, 1, 0,
                                                  0, 0, 0, 0, 1]

    /// Luminance weights used by `Greyscale` (Rec. 601; the manual does not name any).
    public static let greyWeights = (r: 0.299, g: 0.587, b: 0.114)

    /// Opacity (0…255) to draw the image with: ImageAlpha, else the alpha of ImageTint; 255 when a ColorMatrix is
    /// set ("If set, this overrides ImageTint and ImageAlpha" — the matrix's own alpha row applies instead).
    public var drawAlpha: Double {
        if colorMatrix != nil { return 255 }
        return (alpha ?? tint.a).clamped(0, 255)
    }

    /// The color transform baked into the image, as a row-major 5×5 matrix in the manual's convention
    /// (`[R G B A 1] × M`, components 0…1, not premultiplied), or nil when colors are unchanged. Greyscale is
    /// applied first; then either the ColorMatrix, or the RGB of ImageTint (multiplied, so white is neutral and
    /// "Greyscale + ImageTint recolors the image"). Alpha from ImageTint/ImageAlpha is not included: it is applied
    /// when drawing (`drawAlpha`), so fading an image does not re-process it.
    public var processingMatrix: [Double]? {
        var m: [Double]? = nil
        if greyscale {
            let w = ImageOptions.greyWeights
            m = [w.r, w.r, w.r, 0, 0,
                 w.g, w.g, w.g, 0, 0,
                 w.b, w.b, w.b, 0, 0,
                 0, 0, 0, 1, 0,
                 0, 0, 0, 0, 1]
        }
        var second: [Double]? = colorMatrix
        if second == nil, tint.r != 255 || tint.g != 255 || tint.b != 255 {
            var t = ImageOptions.identityMatrix
            t[0] = tint.r / 255
            t[6] = tint.g / 255
            t[12] = tint.b / 255
            second = t
        }
        if let s = second { m = m.map { ImageOptions.multiply($0, s) } ?? s }
        if let result = m, result == ImageOptions.identityMatrix { return nil }
        return m
    }

    /// 5×5 row-major product `a × b` (apply `a`, then `b`, for row vectors).
    public static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        guard a.count == 25, b.count == 25 else { return identityMatrix }
        var r = [Double](repeating: 0, count: 25)
        for i in 0..<5 {
            for j in 0..<5 {
                var s = 0.0
                for k in 0..<5 { s += a[i * 5 + k] * b[k * 5 + j] }
                r[i * 5 + j] = s
            }
        }
        return r
    }

    /// Applies `processingMatrix`-style matrix to one unpremultiplied color (components 0…1), clamping the result.
    public static func apply(_ m: [Double], r: Double, g: Double, b: Double, a: Double)
        -> (r: Double, g: Double, b: Double, a: Double) {
        guard m.count == 25 else { return (r, g, b, a) }
        func out(_ j: Int) -> Double {
            (r * m[j] + g * m[5 + j] + b * m[10 + j] + a * m[15 + j] + m[20 + j]).clamped(0, 1)
        }
        return (out(0), out(1), out(2), out(3))
    }

    // MARK: Geometry

    /// Size after EXIF orientation (orientations 5…8 swap width and height), ImageCrop and ImageRotate: the
    /// natural size of an image meter without W/H ("ImageCrop / ImageRotate will change the size of the entire
    /// meter container"). Image sizes are limited to `maxSide`.
    public func displaySize(imageWidth: Double, imageHeight: Double, exifOrientation: Int = 1)
        -> (width: Double, height: Double) {
        let lim = ImageOptions.maxSide
        var w = imageWidth.isFinite ? imageWidth.clamped(0, lim) : 0
        var h = imageHeight.isFinite ? imageHeight.clamped(0, lim) : 0
        if useExifOrientation, (5...8).contains(exifOrientation) { swap(&w, &h) }
        if let crop {
            let r = crop.rect(imageWidth: w, imageHeight: h)
            w = r.width
            h = r.height
        }
        return ImageOptions.rotatedSize(width: w, height: h, degrees: rotate)
    }

    /// Bounding box of a `width`×`height` rectangle rotated by `degrees` (exact for multiples of 90°).
    public static func rotatedSize(width: Double, height: Double, degrees: Double) -> (width: Double, height: Double) {
        guard degrees.isFinite, width.isFinite, height.isFinite else { return (0, 0) }
        let d = degrees.truncatingRemainder(dividingBy: 360)
        if d == 0 { return (width, height) }
        if abs(d) == 180 { return (width, height) }
        if abs(d) == 90 || abs(d) == 270 { return (height, width) }
        let rad = d * .pi / 180
        let c = abs(cos(rad)), s = abs(sin(rad))
        return (width * c + height * s, width * s + height * c)
    }
}

/// Pure layout helpers for drawing images into meter rectangles (used by the renderer, tested in the core).
public enum ImageGeometry {
    /// Where an image of `imageWidth`×`imageHeight` is drawn inside `bounds`:
    /// PreserveAspectRatio 0 stretches to the bounds; 1 fits inside keeping the aspect ratio; 2 fills the bounds
    /// keeping the aspect ratio (the caller clips the overflow). 1 and 2 center the image (judgment call).
    public static func placement(imageWidth: Double, imageHeight: Double, in bounds: SkinRect,
                                 preserveAspectRatio: Int) -> SkinRect {
        guard preserveAspectRatio == 1 || preserveAspectRatio == 2, imageWidth > 0, imageHeight > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let sx = bounds.width / imageWidth, sy = bounds.height / imageHeight
        let s = preserveAspectRatio == 1 ? min(sx, sy) : max(sx, sy)
        let w = imageWidth * s, h = imageHeight * s
        return SkinRect(x: bounds.x + (bounds.width - w) / 2, y: bounds.y + (bounds.height - h) / 2,
                        width: w, height: h)
    }

    /// Nine-slice pieces for `ScaleMargins=L,T,R,B`: corners keep their size, edges stretch in one direction, the
    /// center in both. Margins are clamped to the image, and shrunk proportionally when the destination is
    /// smaller than the two margins together. Empty pieces are omitted. Source rects are in image pixels
    /// (top-left origin).
    public static func nineSlice(imageWidth iw: Double, imageHeight ih: Double, margins: SkinInsets,
                                 into dest: SkinRect) -> [(source: SkinRect, destination: SkinRect)] {
        guard iw > 0, ih > 0, dest.width > 0, dest.height > 0 else { return [] }
        func fit(_ a: Double, _ b: Double, _ total: Double) -> (Double, Double) {
            let a = a.isFinite ? max(a, 0) : 0, b = b.isFinite ? max(b, 0) : 0
            guard a + b > total, a + b > 0 else { return (a, b) }
            return (a * total / (a + b), b * total / (a + b))
        }
        let (sl, sr) = fit(margins.left, margins.right, iw)
        let (st, sb) = fit(margins.top, margins.bottom, ih)
        let (dl, dr) = fit(sl, sr, dest.width)
        let (dt, db) = fit(st, sb, dest.height)
        let srcX = [0, sl, iw - sr], srcW = [sl, iw - sl - sr, sr]
        let srcY = [0, st, ih - sb], srcH = [st, ih - st - sb, sb]
        let dstX = [dest.x, dest.x + dl, dest.maxX - dr], dstW = [dl, dest.width - dl - dr, dr]
        let dstY = [dest.y, dest.y + dt, dest.maxY - db], dstH = [dt, dest.height - dt - db, db]
        var pieces: [(SkinRect, SkinRect)] = []
        for row in 0..<3 {
            for col in 0..<3 where srcW[col] > 0 && srcH[row] > 0 && dstW[col] > 0 && dstH[row] > 0 {
                pieces.append((SkinRect(x: srcX[col], y: srcY[row], width: srcW[col], height: srcH[row]),
                               SkinRect(x: dstX[col], y: dstY[row], width: dstW[col], height: dstH[row])))
            }
        }
        return pieces
    }

    /// Frame layout of a strip image (Bitmap and Button meters): "the orientation is determined automatically from
    /// the height or the width of the image" — wider than tall means frames side by side, otherwise stacked.
    /// Returns the frame size (whole pixels) and orientation.
    public static func stripFrames(imageWidth iw: Double, imageHeight ih: Double, count: Int)
        -> (width: Double, height: Double, horizontal: Bool) {
        let n = Double(max(count, 1))
        guard iw.isFinite, ih.isFinite, iw > 0, ih > 0 else { return (0, 0, true) }
        if iw > ih { return ((iw / n).rounded(.down), ih, true) }
        return (iw, (ih / n).rounded(.down), false)
    }

    /// Whole-pixel size of a `width`×`height` area rendered at `scale` (device pixels per point), or nil when it is
    /// empty, not finite, or larger than `maxPixels` in total. Checked in floating point before converting, so
    /// hostile meter sizes (`W=(10**300)`) cannot trap an integer conversion.
    public static func pixelSize(width: Double, height: Double, scale: Double, maxPixels: Int) -> (Int, Int)? {
        let w = (width * scale).rounded(), h = (height * scale).rounded()
        // 2^52 keeps the Double comparison exact and every side far below Int.max.
        guard w.isFinite, h.isFinite, w >= 1, h >= 1, w * h <= Double(min(max(maxPixels, 0), 1 << 52))
        else { return nil }
        return (Int(w), Int(h))
    }

    /// Source rectangle (image pixels) of frame `index` in a strip.
    public static func stripFrameRect(index: Int, frameWidth: Double, frameHeight: Double, horizontal: Bool) -> SkinRect {
        let i = Double(max(index, 0))
        return horizontal ? SkinRect(x: i * frameWidth, y: 0, width: frameWidth, height: frameHeight)
            : SkinRect(x: 0, y: i * frameHeight, width: frameWidth, height: frameHeight)
    }
}

/// Optional image queries a `SkinHost` can answer in addition to `imageSize(atPath:)`. The app's hosts conform;
/// hosts that do not (test fakes) get EXIF orientation 1 and fully opaque images.
public protocol SkinImageQueries: AnyObject {
    /// EXIF orientation (1…8) stored in the image file; 1 when absent or unknown.
    func imageExifOrientation(atPath path: String) -> Int
    /// Alpha (0…255) of pixel (`x`, `y`) (top-left origin) of the image file — after EXIF orientation when
    /// `exifOriented` — or nil when unknown (callers treat unknown as opaque).
    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double?
}

extension Meter {
    /// Raw pixel size of an image file from the host, after EXIF orientation when `options` asks for it, crop and
    /// rotation (`ImageOptions.displaySize`). Nil when the host cannot load it.
    func imageDisplaySize(_ path: String?, _ options: ImageOptions) -> (width: Double, height: Double)? {
        guard let path, let host = skin.host, let raw = host.imageSize(atPath: path) else { return nil }
        let orientation = options.useExifOrientation
            ? ((host as? SkinImageQueries)?.imageExifOrientation(atPath: path) ?? 1) : 1
        return options.displaySize(imageWidth: raw.width, imageHeight: raw.height, exifOrientation: orientation)
    }

    /// Alpha of an image pixel via `SkinImageQueries` (nil = unknown, treat as opaque).
    func imagePixelAlpha(_ path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        (skin.host as? SkinImageQueries)?.imagePixelAlpha(atPath: path, x: x, y: y, exifOriented: exifOriented)
    }
}
