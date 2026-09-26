import Foundation

/// `Meter=Image` (manual: Meters → Image, plus General Image Options).
///
/// - The file comes from the bound measures (`MeasureName`, `MeasureName2`…) or `ImageName`. A bound measure
///   overrides a plain ImageName; an ImageName containing `%1`, `%2`… is a template filled with the measures'
///   string values (`ImageName=%1.jpg`, `ImageName=%1-%2.png`). `ImagePath` (or the deprecated `Path`) is the
///   folder for relative names; `.png` is assumed without an extension.
/// - Size: W×H when both are given. Otherwise the image's size after EXIF orientation / ImageCrop / ImageRotate;
///   with only one of W/H the other follows the aspect ratio ("If only one of either W or H is defined, then
///   PreserveAspectRatio will default to 1") — unless PreserveAspectRatio=0 is written explicitly, which keeps
///   the image's own size for the missing side (judgment call: the manual says *default*).
/// - `Tile=1` repeats the image unscaled; `ScaleMargins` nine-slices it (only with Tile=0 and
///   PreserveAspectRatio=0).
/// - `MaskImageName` (+ `MaskImagePath`, `MaskImageFlip`, `MaskImageRotate`): W/H (or the mask's own size) is the
///   meter size; the primary image fills it keeping its aspect ratio (cropped), and the result keeps the most
///   transparent alpha of image and mask. Tile and ScaleMargins do not apply. ImagePath is not used for the mask.
/// - Images are cached by the app and reloaded when the file changes on disk, so `DynamicVariables=1` is not
///   needed for that (the manual's reason to use it); DynamicVariables still re-reads every option.
public final class ImageMeter: Meter {
    /// Absolute path of the image to draw (nil = nothing).
    public private(set) var imagePath: String?
    /// Effective PreserveAspectRatio: 0 stretch, 1 fit keeping aspect, 2 fill keeping aspect (crop).
    public private(set) var preserveAspectRatio = 0
    public private(set) var imageOptions = ImageOptions()
    public private(set) var tile = false
    /// `ScaleMargins=L,T,R,B` (nine-slice scaling).
    public private(set) var scaleMargins: SkinInsets?
    /// `MaskImageName` resolved against `MaskImagePath` (nil = no mask).
    public private(set) var maskImagePath: String?
    /// Flip / rotate of the mask image (`MaskImageFlip`, `MaskImageRotate`).
    public private(set) var maskOptions = ImageOptions()

    /// `ImageTint` when it is not the neutral default.
    public var imageTint: RGBA? { imageOptions.tint == .white ? nil : imageOptions.tint }
    /// `ImageAlpha` (255 when not set).
    public var imageAlpha: Double { imageOptions.alpha ?? 255 }
    public var greyscale: Bool { imageOptions.greyscale }
    public var flipHorizontal: Bool { imageOptions.flip.horizontal }
    public var flipVertical: Bool { imageOptions.flip.vertical }
    /// Degrees, clockwise.
    public var imageRotate: Double { imageOptions.rotate }
    /// `ImageCrop=X,Y,W,H,Origin`.
    public var imageCrop: [Double]? {
        imageOptions.crop.map { [$0.x, $0.y, $0.width, $0.height, Double($0.origin)] }
    }

    private var nameTemplate = ""
    private var imagePathOption = ""
    private var lastCheckedPath: String?

    public override func readMeterOptions() {
        nameTemplate = string("ImageName")
        imagePathOption = ImageOptions.imagePathOption(self)
        if imagePathOption.isEmpty { imagePathOption = string("Path").trimmingCharacters(in: .whitespaces) }
        imageOptions = ImageOptions.read(from: self)

        let onlyOneSide = (widthOption == nil) != (heightOption == nil)
        if let par = optionalDouble("PreserveAspectRatio"), par.isFinite {
            preserveAspectRatio = Int(par.clamped(0, 2))
        } else {
            preserveAspectRatio = onlyOneSide ? 1 : 0
        }
        tile = bool("Tile", false)
        let margins = OptionValue.numbers(string("ScaleMargins"))
        if margins.count >= 4, margins.prefix(4).contains(where: { $0 > 0 }) {
            scaleMargins = SkinInsets(left: max(margins[0], 0), top: max(margins[1], 0),
                                      right: max(margins[2], 0), bottom: max(margins[3], 0))
        } else {
            scaleMargins = nil
        }

        let maskName = string("MaskImageName")
        maskImagePath = ImageOptions.filePath(maskName, imagePath: string("MaskImagePath"), skin: skin)
        var mask = ImageOptions()
        mask.flip = ImageOptions.Flip.parse(string("MaskImageFlip", "None"))
        let maskRotate = double("MaskImageRotate", 0)
        mask.rotate = maskRotate.isFinite ? maskRotate.truncatingRemainder(dividingBy: 360) : 0
        maskOptions = mask
        resolveImagePath()
    }

    public override func updateMeter() {
        resolveImagePath()
        // Log a missing file once per path (only here: before the first update, bound measures are still empty).
        if imagePath != lastCheckedPath {
            lastCheckedPath = imagePath
            if let imagePath, let host = skin.host, host.imageSize(atPath: imagePath) == nil {
                skin.log("[\(name)] Unable to open image: \(imagePath)", level: .warning)
            }
        }
    }

    /// File name from ImageName / the bound measures (see the type comment). `%N` means `MeasureNameN` (slot N,
    /// even when an earlier MeasureName names no measure) and is replaced in one pass, so a measure value that
    /// itself contains `%2` is not substituted again; a slot without a measure becomes empty. Without a
    /// placeholder, the measure of `MeasureName` (slot 1) gives the name.
    func imageName() -> String {
        guard !measures.isEmpty else { return nameTemplate }
        if ImageMeter.hasPlaceholder(nameTemplate) {
            let slots = measureSlots
            return StringMeter.substitute(nameTemplate, count: slots.count) { index in
                guard index >= 1, index <= slots.count else { return nil }
                return slots[index - 1]?.stringValue ?? ""
            }
        }
        return (measureSlots.first ?? nil)?.stringValue ?? nameTemplate
    }

    private static func hasPlaceholder(_ s: String) -> Bool {
        var previousPercent = false
        for u in s.utf8 {
            if previousPercent, u >= 0x30, u <= 0x39 { return true }
            previousPercent = u == 0x25
        }
        return false
    }

    private func resolveImagePath() {
        imagePath = ImageOptions.filePath(imageName(), imagePath: imagePathOption, skin: skin)
    }

    /// Size of the image after EXIF orientation, crop and rotation (nil when it cannot be loaded).
    public var imageDisplaySize: (width: Double, height: Double)? {
        imageDisplaySize(imagePath, imageOptions)
    }

    /// Size of the mask image after its flip/rotation (nil without a loadable mask).
    public var maskDisplaySize: (width: Double, height: Double)? {
        imageDisplaySize(maskImagePath, maskOptions)
    }

    public override func naturalSize() -> (width: Double, height: Double) {
        let size: (width: Double, height: Double)
        if maskImagePath != nil {
            guard let m = maskDisplaySize else { return (0, 0) }
            size = m
        } else {
            guard let s = imageDisplaySize else { return (0, 0) }
            size = s
        }
        let w = size.width, h = size.height
        if !tile, preserveAspectRatio != 0, w > 0, h > 0 {
            let lim = ImageOptions.maxSide * 4
            if let widthOption, heightOption == nil { return (widthOption, (widthOption * h / w).clamped(0, lim)) }
            if let heightOption, widthOption == nil { return ((heightOption * w / h).clamped(0, lim), heightOption) }
        }
        return (w, h)
    }

    /// Where the image is drawn inside the content rect (PreserveAspectRatio applied; for 2 it overflows and the
    /// renderer clips). Nil without a loadable image.
    public func imageDestination() -> SkinRect? {
        guard let size = imageDisplaySize else { return nil }
        return ImageGeometry.placement(imageWidth: size.width, imageHeight: size.height, in: contentFrame,
                                       preserveAspectRatio: maskImagePath != nil ? 2 : preserveAspectRatio)
    }
}
