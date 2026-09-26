import AppKit
import DesksetCore

extension SkinRenderer {
    // MARK: Rotator

    /// Draws the (processed) image at its pixel size through `RotatorMeter.imageTransform`, which puts the image
    /// point OffsetX/OffsetY on the center of rotation and turns the image by the current angle. The image is
    /// always drawn with smooth interpolation, like the Image meter; it is not clipped to the meter box.
    /// A plain opacity (ImageAlpha / ImageTint alpha) is applied while drawing, not baked into the cached image.
    /// `UseExifOrientation=1` turns the image upright first (OffsetX / OffsetY are then upright image pixels).
    static func drawRotator(_ meter: RotatorMeter, _ ctx: CGContext, _ context: SkinRenderContext) {
        let (processing, opacity) = meter.imageProcessing.opacitySplit
        guard opacity > 0, let path = meter.imagePath,
              let source = Images.cgImage(atPath: path, exifOriented: processing.useExifOrientation),
              let image = context.rotatorImages.image(for: source, path: path, processing: processing)
        else { return }
        let t = meter.imageTransform
        guard t.a.isFinite, t.b.isFinite, t.c.isFinite, t.d.isFinite, t.tx.isFinite, t.ty.isFinite else { return }
        ctx.saveGState()
        ctx.concatenate(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty))
        drawCGImage(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), ctx,
                    alpha: CGFloat(opacity))
        ctx.restoreGState()
    }
}

/// A skin's Rotator images with the general image options applied (crop → flip → ImageRotate → color matrix), computed
/// once per image and option set (`SkinRenderContext.rotatorImages`; a Rotator's processed images belong to its skin).
/// An entry is rebuilt when `Images` hands out a new decode (file changed on disk).
/// The cache is bounded by bytes and evicts the least recently used entries, so a skin that keeps changing an
/// option (a tint animation…) cannot pile up dozens of full-size bitmaps, and a working set of many small
/// processed images is not thrown away all at once.
///
/// The bytes are counted for all skins together (`Budget`): each skin may keep `Budget.perSkin` (16 MB) whatever the
/// others hold, and more only while all skins' caches together stay within `Budget.total` (64 MB, what the one cache
/// shared by every skin used to keep). So one skin with many large needles keeps them all, as before, and a suite of
/// skins that each keep changing a tint does not keep 64 MB per skin.
final class RotatorImageCache {
    /// What the Rotator image caches of all skins hold together. Any thread: each skin's cache counts its own bytes in
    /// and out, from its own thread.
    final class Budget {
        let total: Int
        let perSkin: Int
        private let held = Guarded(0)

        init(total: Int, perSkin: Int) {
            self.total = total
            self.perSkin = perSkin
        }

        /// Bytes held by all caches.
        var bytes: Int { held.current }

        fileprivate func add(_ bytes: Int) {
            held.access { $0 += bytes }
        }
    }

    static let budget = Budget(total: 64 << 20, perSkin: 16 << 20)

    private struct Key: Hashable {
        let path: String
        let processing: RotatorMeter.ImageProcessing
    }

    private struct Entry {
        let source: CGImage
        let image: CGImage?
        /// Bytes owned by this entry (0 when `image` is the shared decoded source).
        let bytes: Int
        var lastUse: UInt64
    }

    private let budget: Budget
    private var entries: [Key: Entry] = [:]
    private var totalBytes = 0
    private var useClock: UInt64 = 0
    private static let maxEntries = 256
    /// Processed canvases larger than this many pixels are not built (the unprocessed image is drawn instead).
    private static let maxPixels = 4096 * 4096

    init(budget: Budget = RotatorImageCache.budget) {
        self.budget = budget
    }

    deinit {
        budget.add(-totalBytes)
    }

    /// How many processed images the cache holds (self-tests).
    var count: Int { entries.count }

    func image(for source: CGImage, path: String, processing: RotatorMeter.ImageProcessing) -> CGImage? {
        if processing.isIdentity { return source }
        useClock &+= 1
        let key = Key(path: path, processing: processing)
        if var hit = entries[key], hit.source === source {
            hit.lastUse = useClock
            entries[key] = hit
            return hit.image
        }
        if let stale = entries.removeValue(forKey: key) { forget(stale.bytes) }
        let image = Self.process(source, processing)
        let bytes = image.map { $0 === source ? 0 : $0.bytesPerRow * $0.height } ?? 0
        // The new entry is always kept (even one bigger than the budget, which then evicts everything else), so
        // a large processed image is not rebuilt on every frame.
        while !entries.isEmpty, entries.count >= Self.maxEntries || overBudget(adding: bytes) {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            forget(oldest.value.bytes)
            entries.removeValue(forKey: oldest.key)
        }
        entries[key] = Entry(source: source, image: image, bytes: bytes, lastUse: useClock)
        totalBytes += bytes
        budget.add(bytes)
        return image
    }

    /// Whether keeping `bytes` more would take this skin past its share while all skins together are past the total.
    private func overBudget(adding bytes: Int) -> Bool {
        totalBytes + bytes > budget.perSkin && budget.bytes + bytes > budget.total
    }

    private func forget(_ bytes: Int) {
        totalBytes -= bytes
        budget.add(-bytes)
    }

    private static func process(_ source: CGImage, _ p: RotatorMeter.ImageProcessing) -> CGImage? {
        var image = source
        if let crop = p.crop {
            let r = crop.rect(imageWidth: Double(image.width), imageHeight: Double(image.height))
            guard let canvas = canvas(width: r.width, height: r.height) else { return source }
            SkinRenderer.drawCGImage(image, in: CGRect(x: -r.x, y: -r.y, width: Double(image.width),
                                                       height: Double(image.height)), canvas)
            guard let cropped = canvas.makeImage() else { return source }
            image = cropped
        }
        if p.flipHorizontal || p.flipVertical || p.rotateDegrees != 0 {
            let w = Double(image.width), h = Double(image.height)
            let radians = p.rotateDegrees * .pi / 180
            // ImageRotate grows the image to the rotated bounding box (manual: it "will change the size of the
            // entire meter container to the size of the rotated image").
            let bw = abs(w * cos(radians)) + abs(h * sin(radians))
            let bh = abs(w * sin(radians)) + abs(h * cos(radians))
            guard let canvas = canvas(width: bw.rounded(), height: bh.rounded()) else { return image }
            canvas.translateBy(x: CGFloat(canvas.width) / 2, y: CGFloat(canvas.height) / 2)
            canvas.rotate(by: CGFloat(radians))
            canvas.scaleBy(x: p.flipHorizontal ? -1 : 1, y: p.flipVertical ? -1 : 1)
            SkinRenderer.drawCGImage(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), canvas)
            if let turned = canvas.makeImage() { image = turned }
        }
        if let matrix = p.colorMatrix, matrix.count == 25 {
            image = applyColorMatrix(matrix, to: image) ?? image
        }
        return image
    }

    /// A transparent RGBA bitmap context with a top-left origin (y down), or nil for an empty / oversized one.
    private static func canvas(width: Double, height: Double) -> CGContext? {
        guard width.isFinite, height.isFinite else { return nil }
        let w = Int(min(max(width.rounded(.up), 0), 16384)), h = Int(min(max(height.rounded(.up), 0), 16384))
        guard w > 0, h > 0, w * h <= maxPixels,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        return ctx
    }

    /// `[r g b a 1] × M` per pixel on unpremultiplied 0…1 components, results clamped to 0…1.
    private static func applyColorMatrix(_ m: [Double], to image: CGImage) -> CGImage? {
        guard let ctx = canvas(width: Double(image.width), height: Double(image.height)) else { return nil }
        SkinRenderer.drawCGImage(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), ctx)
        guard let data = ctx.data else { return nil }
        let bytesPerRow = ctx.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * ctx.height)
        let mf = m.map { Float($0) }
        @inline(__always) func clamp01(_ v: Float) -> Float { v.isNaN ? 0 : min(max(v, 0), 1) }
        for y in 0..<ctx.height {
            var i = y * bytesPerRow
            for _ in 0..<ctx.width {
                let a = Float(pixels[i + 3]) / 255
                var r: Float = 0, g: Float = 0, b: Float = 0
                if a > 0 {
                    r = min(Float(pixels[i]) / 255 / a, 1)
                    g = min(Float(pixels[i + 1]) / 255 / a, 1)
                    b = min(Float(pixels[i + 2]) / 255 / a, 1)
                }
                let nr = clamp01(r * mf[0] + g * mf[5] + b * mf[10] + a * mf[15] + mf[20])
                let ng = clamp01(r * mf[1] + g * mf[6] + b * mf[11] + a * mf[16] + mf[21])
                let nb = clamp01(r * mf[2] + g * mf[7] + b * mf[12] + a * mf[17] + mf[22])
                let na = clamp01(r * mf[3] + g * mf[8] + b * mf[13] + a * mf[18] + mf[23])
                pixels[i] = UInt8((nr * na * 255).rounded())
                pixels[i + 1] = UInt8((ng * na * 255).rounded())
                pixels[i + 2] = UInt8((nb * na * 255).rounded())
                pixels[i + 3] = UInt8((na * 255).rounded())
                i += 4
            }
        }
        return ctx.makeImage()
    }
}
