import Foundation

/// `Meter=Bitmap` (manual: Meters → Bitmap): shows frame(s) of a strip image depending on a measure value.
///
/// - `BitmapImage` (+ ImagePath and the general image options except ImageCrop/ImageRotate): `BitmapFrames`
///   frames laid out side by side when the image is wider than tall, stacked otherwise. W and H are ignored; the
///   meter is one frame high and as wide as the drawn frames.
/// - Normal mode: the percentual value picks one frame — with 5 frames 0–19% is the first, 20–39% the second…
///   (100% is clamped to the last frame). `BitmapZeroFrame=1` reserves the first frame for exactly 0% and spreads
///   the rest over the other frames, so 100% is the last frame (judgment call on the manual's wording).
/// - `BitmapExtend=1`: the value, rounded to an integer, is drawn digit by digit with one frame per digit (frame
///   *d* shows digit *d*; the number base is the number of frames, i.e. 10 for a 0–9 strip). `BitmapDigits` fixes
///   the number of digits (leading positions use the first frame; a longer value keeps its lowest digits —
///   judgment call); 0 draws as many as needed. Negative values are drawn without sign (judgment call).
///   `BitmapSeparation` adds pixels between digits; `BitmapAlign` Left/Center/Right makes X the left edge, center
///   or right edge of the number (like StringAlign). Digits are always laid out horizontally.
/// - `BitmapTransitionFrames=T`: every real frame is followed by T transition frames (BitmapFrames counts all
///   of them). When a shown frame changes, the T frames that follow the old frame play first, one per
///   `[Rainmeter] TransitionUpdate` ms (default 100), then the new frame is shown. The frames are stepped on the
///   skin's executor; closing the skin stops a running transition.
public final class BitmapMeter: Meter, PluginLifecycle {
    public enum Align: Hashable { case left, center, right }

    public private(set) var bitmapImagePath: String?
    public private(set) var imageOptions = ImageOptions()
    public private(set) var frames = 1
    public private(set) var transitionFrames = 0
    public private(set) var zeroFrame = false
    public private(set) var extend = false
    public private(set) var digits = 0
    public private(set) var align = Align.left
    public private(set) var separation = 0.0
    /// Strip frame index (0-based, transition frames included) of every drawn cell, left to right.
    public private(set) var displayedFrames: [Int] = [0]

    /// Real (non-transition) frame of every cell that the current transition started from, and the target.
    private var shownReal: [Int] = [0]
    private var targetReal: [Int] = [0]
    /// 0 when idle, 1…transitionFrames while a transition plays.
    private(set) var transitionStep = 0
    private var transitionGeneration = 0
    /// The next transition frame, waiting on the skin's executor.
    private var transitionTick: SkinScheduledWork?
    private var closed = false
    private var hasValue = false

    /// Upper bound on drawn digits (an Int64 needs at most 64 digits in base 2).
    static let maxDigits = 64
    /// Largest magnitude drawn with BitmapExtend: the manual allows int64 values; this is the largest Double below
    /// 2^63.
    static let maxValue = 9_223_372_036_854_774_784.0

    public override func readMeterOptions() {
        // "All general meter options are valid, except W and H."
        widthOption = nil
        heightOption = nil
        imageOptions = ImageOptions.read(from: self, crop: false, rotate: false)
        bitmapImagePath = ImageOptions.filePath(string("BitmapImage"), imagePath: ImageOptions.imagePathOption(self),
                                                skin: skin)
        frames = clampInt(int("BitmapFrames", 1), 1, 100_000)
        transitionFrames = clampInt(int("BitmapTransitionFrames", 0), 0, frames - 1)
        zeroFrame = bool("BitmapZeroFrame", false)
        extend = bool("BitmapExtend", false)
        digits = clampInt(int("BitmapDigits", 0), 0, BitmapMeter.maxDigits)
        switch string("BitmapAlign", "Left").trimmingCharacters(in: .whitespaces).lowercased() {
        case "center": align = .center
        case "right": align = .right
        default: align = .left
        }
        let sep = double("BitmapSeparation", 0)
        separation = sep.isFinite ? sep.clamped(-ImageOptions.maxSide, ImageOptions.maxSide) : 0
    }

    /// Frames that are not transition frames.
    public var realFrames: Int { max(frames / (transitionFrames + 1), 1) }

    public override func updateMeter() {
        let targets = targetFrames()
        if !hasValue || transitionFrames == 0 || targets.count != shownReal.count {
            hasValue = true
            shownReal = targets
            targetReal = targets
            transitionStep = 0
            transitionGeneration &+= 1
        } else if targets != targetReal || (transitionStep == 0 && targets != shownReal) {
            // A change mid-transition finishes the running one first (judgment call).
            if transitionStep > 0 { shownReal = targetReal }
            targetReal = targets
            if targets != shownReal {
                transitionStep = 1
                scheduleTransitionTick()
            } else {
                transitionStep = 0
            }
        }
        refreshDisplayedFrames()
    }

    public func skinWillClose() {
        closed = true
        transitionTick?.cancel()
        transitionTick = nil
    }

    deinit {
        transitionTick?.cancel()
    }

    /// Real frame (0…realFrames-1) for every cell from the bound measure's value.
    func targetFrames() -> [Int] {
        let n = realFrames
        let measure = measureSlots.first ?? nil
        if !extend {
            let p = measure?.relativeValue ?? 0
            let frame: Int
            if zeroFrame {
                frame = p <= 0 ? 0 : Int((p * Double(n - 1)).rounded(.up).clamped(0, Double(n - 1)))
            } else {
                frame = Int((p * Double(n)).rounded(.down).clamped(0, Double(n - 1)))
            }
            return [frame]
        }
        let raw = measure?.value ?? 0
        let rounded = raw.isFinite ? raw.rounded().clamped(-BitmapMeter.maxValue, BitmapMeter.maxValue) : 0
        var v = UInt64(abs(rounded))
        let base = UInt64(max(n, 2))
        var list: [Int] = []
        repeat {
            list.append(n < 2 ? 0 : Int(v % base))
            v /= base
        } while v > 0 && list.count < BitmapMeter.maxDigits
        if digits > 0 {
            if list.count > digits { list.removeLast(list.count - digits) }
            while list.count < digits { list.append(0) }
        }
        return list.reversed()
    }

    private func refreshDisplayedFrames() {
        let t = transitionFrames + 1
        displayedFrames = zip(shownReal, targetReal).map { shown, target in
            let base = shown * t
            let frame = transitionStep > 0 && shown != target ? base + transitionStep : base
            return min(max(frame, 0), frames - 1)
        }
        if displayedFrames.isEmpty { displayedFrames = [0] }
    }

    private func scheduleTransitionTick() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        // A tick still waiting belongs to an older generation, which it would skip anyway.
        transitionTick?.cancel()
        transitionTick = nil
        guard !closed else { return }
        let interval = Double(clampInt(skin.rainmeterSection?.int("TransitionUpdate", 100) ?? 100, 1, 60_000)) / 1000
        transitionTick = skin.executor.async(after: interval) { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.transitionTick = nil
            self.advanceTransition()
        }
    }

    /// Shows the next transition frame (called by the transition timer; tests call it directly).
    func advanceTransition() {
        guard transitionStep > 0 else { return }
        transitionStep += 1
        if transitionStep > transitionFrames {
            transitionStep = 0
            shownReal = targetReal
            transitionGeneration &+= 1
        } else {
            scheduleTransitionTick()
        }
        refreshDisplayedFrames()
        skin.redraw()
    }

    // MARK: Geometry

    /// Frame size and strip orientation from the (EXIF-oriented) image size; nil without a loadable image.
    public var frameLayout: (width: Double, height: Double, horizontal: Bool)? {
        guard let size = imageDisplaySize(bitmapImagePath, imageOptions) else { return nil }
        return ImageGeometry.stripFrames(imageWidth: size.width, imageHeight: size.height, count: frames)
    }

    public override func naturalSize() -> (width: Double, height: Double) {
        guard let f = frameLayout else { return (0, 0) }
        let n = Double(max(displayedFrames.count, 1))
        return (max(n * f.width + (n - 1) * separation, 0), f.height)
    }

    public override func anchorOffset(width: Double, height: Double) -> (dx: Double, dy: Double) {
        guard extend else { return (0, 0) }
        switch align {
        case .left: return (0, 0)
        // Whole pixels, so an odd width does not put the digit images on half pixels (blurred on 1x screens).
        case .center: return (-(width / 2).rounded(.down), 0)
        case .right: return (-width, 0)
        }
    }

    /// What to draw: for every cell, the strip frame, its source rectangle in image pixels and the destination in
    /// skin coordinates.
    public func cells() -> [(frame: Int, source: SkinRect, destination: SkinRect)] {
        guard let f = frameLayout, f.width > 0, f.height > 0 else { return [] }
        let c = contentFrame
        return displayedFrames.enumerated().map { i, frame in
            (frame, ImageGeometry.stripFrameRect(index: frame, frameWidth: f.width, frameHeight: f.height,
                                                 horizontal: f.horizontal),
             SkinRect(x: c.x + Double(i) * (f.width + separation), y: c.y, width: f.width, height: f.height))
        }
    }
}

/// `value` limited to `lo…hi` (`hi` below `lo` counts as `lo`).
private func clampInt(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
    Swift.min(Swift.max(value, lo), Swift.max(lo, hi))
}
