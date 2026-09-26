import Accelerate
import AppKit
import ImageIO
import DesksetCore

/// Decoded image files and images derived from them (EXIF-oriented, cropped, color-transformed, flattened,
/// strip frames, masks), all cached. A file is re-checked with one `stat` per lookup and reloaded — and its
/// derived images dropped — when its modification time, size or inode changes; decoding happens once per
/// version of the file.
///
/// Formats: whatever ImageIO decodes — the manual's .png, .jpg, .bmp, .gif (first frame only, "no animation
/// supported"), .tif, .webp and .ico (the largest icon in the file). Everything runs on the main thread.
enum Images {
    /// Decoded files are limited to this many pixels per side (larger files are downsampled while decoding).
    static let maxDecodeSide = 8192
    /// Files that declare more pixels than this are not decoded at all (a hostile or corrupt header must not make
    /// ImageIO allocate gigabytes; 16384×16384).
    static let maxSourcePixels = 1 << 28
    /// Derived bitmaps larger than this many pixels are not created (the plain image is drawn instead).
    static let maxDerivedPixels = 16_777_216
    /// Memory budget (bytes) for decoded files. Beyond it the least recently used files are dropped — a slideshow
    /// skin cycling through a photo folder must not keep every photo decoded — but never a file used in the last
    /// `entryKeepAlive` seconds (it is still on screen; dropping it would decode it again on every frame).
    static let entryCostLimit = 512 << 20
    static let entryKeepAlive: TimeInterval = 5

    /// One decoded version of a file.
    final class Entry {
        let image: CGImage
        let exifOrientation: Int
        let generation: Int
        fileprivate let stamp: FileStamp
        fileprivate let cost: Int
        fileprivate var lastUse: TimeInterval

        fileprivate init(image: CGImage, exifOrientation: Int, generation: Int, stamp: FileStamp, now: TimeInterval) {
            self.image = image
            self.exifOrientation = exifOrientation
            self.generation = generation
            self.stamp = stamp
            cost = image.bytesPerRow * image.height
            lastUse = now
        }
    }

    fileprivate struct FileStamp: Equatable {
        var seconds: Int
        var nanoseconds: Int
        var size: Int64
        var inode: UInt64

        init?(path: String) {
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
            seconds = Int(st.st_mtimespec.tv_sec)
            nanoseconds = Int(st.st_mtimespec.tv_nsec)
            size = Int64(st.st_size)
            inode = UInt64(st.st_ino)
        }
    }

    private static var entries: [String: Entry] = [:]
    private static var entriesCost = 0
    private static var failures: [String: FileStamp] = [:]
    private static var nextGeneration = 1

    // MARK: Files

    /// The current decoded version of the file, or nil when it is missing or cannot be decoded.
    static func entry(atPath path: String) -> Entry? {
        guard let stamp = FileStamp(path: path) else {
            removeEntry(path)
            failures[path] = nil
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let e = entries[path], e.stamp == stamp {
            e.lastUse = now
            return e
        }
        if failures[path] == stamp { return nil }
        removeEntry(path)
        guard let decoded = decode(path) else {
            // Bounded: a measure can name a new undecodable file on every update.
            if failures.count >= 1024 { failures.removeAll() }
            failures[path] = stamp
            return nil
        }
        failures[path] = nil
        let e = Entry(image: decoded.image, exifOrientation: decoded.orientation, generation: nextGeneration,
                      stamp: stamp, now: now)
        nextGeneration += 1
        entries[path] = e
        entriesCost += e.cost
        if entriesCost > entryCostLimit { evictEntries(now: now) }
        return e
    }

    /// Forgets the decoded file and everything derived from it.
    private static func removeEntry(_ path: String) {
        guard let old = entries.removeValue(forKey: path) else { return }
        entriesCost -= old.cost
        dropDerived(path)
    }

    /// Drops least recently used decoded files until the cache is back under 3/4 of its budget, keeping files used
    /// within `entryKeepAlive`.
    private static func evictEntries(now: TimeInterval) {
        let target = entryCostLimit / 4 * 3
        for (path, e) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            guard entriesCost > target, now - e.lastUse > entryKeepAlive else { break }
            removeEntry(path)
        }
    }

    /// The decoded file image as stored (no EXIF orientation applied).
    static func cgImage(atPath path: String) -> CGImage? {
        entry(atPath: path)?.image
    }

    /// The decoded file image, turned upright by its EXIF orientation when `exifOriented` (`UseExifOrientation=1`).
    static func cgImage(atPath path: String, exifOriented: Bool) -> CGImage? {
        guard let e = entry(atPath: path) else { return nil }
        return exifOriented ? oriented(path, e) : e.image
    }

    /// Size in pixels (Rainmeter works in pixels; 1 image pixel = 1 point), as stored in the file.
    static func size(atPath path: String) -> (width: Double, height: Double)? {
        guard let e = entry(atPath: path) else { return nil }
        return (Double(e.image.width), Double(e.image.height))
    }

    /// EXIF orientation (1…8) of the file; 1 when it has none.
    static func exifOrientation(atPath path: String) -> Int {
        entry(atPath: path)?.exifOrientation ?? 1
    }

    static func purge() {
        entries.removeAll()
        entriesCost = 0
        failures.removeAll()
        derived.removeAll()
        derivedFailures.removeAll()
        derivedCost = 0
        alphaMasks.removeAll()
    }

    private static func decode(_ path: String) -> (image: CGImage, orientation: Int)? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        func pixelSize(_ i: Int) -> (Int, Int, Int) {
            let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            return ((p?[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p?[kCGImagePropertyPixelHeight] as? Int) ?? 0,
                    (p?[kCGImagePropertyOrientation] as? Int) ?? 1)
        }
        var index = 0
        let type = (CGImageSourceGetType(source) as String?) ?? ""
        if count > 1, type == "com.microsoft.ico" || type == "com.microsoft.cur" || type == "com.apple.icns" {
            // Icon files hold several sizes: use the largest.
            var best = 0
            for i in 0..<min(count, 64) {
                let (w, h, _) = pixelSize(i)
                if w * h > best {
                    best = w * h
                    index = i
                }
            }
        }
        let (w, h, orientation) = pixelSize(index)
        guard w >= 0, h >= 0, w <= maxSourcePixels, h <= maxSourcePixels, w * h <= maxSourcePixels else { return nil }
        let image: CGImage?
        if max(w, h) > maxDecodeSide {
            image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: maxDecodeSide,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, index,
                                                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image, image.width > 0, image.height > 0 else { return nil }
        return (image, (1...8).contains(orientation) ? orientation : 1)
    }

    // MARK: Derived images

    /// How a derived image is made from its file; with the file's path and generation it is the cache key.
    indirect enum Recipe: Hashable {
        /// EXIF orientation applied.
        case oriented
        /// `UseExifOrientation`, ImageCrop rectangle (pixels) and color matrix — see `prepared(atPath:options:)`.
        case prepared(oriented: Bool, crop: [Int]?, matrix: [Double]?)
        /// A prepared image with ImageFlip / ImageRotate baked in.
        case flattened(Recipe, flipH: Bool, flipV: Bool, rotate: Double)
        /// A sub-rectangle (strip frame, nine-slice piece) of another derived image.
        case region(Recipe, x: Int, y: Int, width: Int, height: Int)
        /// An Image meter's primary image composed with its MaskImage at a pixel size (`maskRecipe` describes the
        /// mask including its flip and rotation).
        case masked(Recipe, flipH: Bool, flipV: Bool, rotate: Double, mask: String, maskGeneration: Int,
                    maskRecipe: Recipe, width: Int, height: Int, scale: Int)
    }

    struct DerivedKey: Hashable {
        let path: String
        let generation: Int
        let recipe: Recipe
    }

    private final class DerivedEntry {
        let image: CGImage
        let cost: Int
        var lastUse: Int

        init(image: CGImage, cost: Int, lastUse: Int) {
            self.image = image
            self.cost = cost
            self.lastUse = lastUse
        }
    }

    private static var derived: [DerivedKey: DerivedEntry] = [:]
    private static var derivedFailures: Set<DerivedKey> = []
    private static var derivedCost = 0
    private static var useCounter = 0
    private static let derivedCostLimit = 256 << 20
    private static let derivedCountLimit = 2048

    /// Cached derived image for `key`, made with `make` on a miss. A failed `make` is remembered too.
    static func derived(_ key: DerivedKey, _ make: () -> CGImage?) -> CGImage? {
        useCounter += 1
        if let hit = derived[key] {
            hit.lastUse = useCounter
            return hit.image
        }
        if derivedFailures.contains(key) { return nil }
        guard let image = make() else {
            if derivedFailures.count > 4096 { derivedFailures.removeAll() }
            derivedFailures.insert(key)
            return nil
        }
        let cost = image.bytesPerRow * image.height
        derived[key] = DerivedEntry(image: image, cost: cost, lastUse: useCounter)
        derivedCost += cost
        if derivedCost > derivedCostLimit || derived.count > derivedCountLimit { evict() }
        return image
    }

    private static func evict() {
        let byAge = derived.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, entry) in byAge {
            guard derivedCost > derivedCostLimit / 2 || derived.count > derivedCountLimit / 2 else { break }
            derived[key] = nil
            derivedCost -= entry.cost
        }
    }

    private static func dropDerived(_ path: String) {
        for (key, entry) in derived where key.path == path {
            derived[key] = nil
            derivedCost -= entry.cost
        }
        derivedFailures = derivedFailures.filter { $0.path != path }
        alphaMasks = alphaMasks.filter { $0.key.path != path }
    }

    /// The file image with its EXIF orientation applied (the stored image when the orientation is 1).
    static func oriented(_ path: String, _ e: Entry) -> CGImage {
        guard e.exifOrientation != 1 else { return e.image }
        return derived(DerivedKey(path: path, generation: e.generation, recipe: .oriented)) {
            orient(e.image, e.exifOrientation)
        } ?? e.image
    }

    /// Draws `image` into a new bitmap with the EXIF `orientation` (2…8) undone.
    private static func orient(_ image: CGImage, _ orientation: Int) -> CGImage? {
        let w = image.width, h = image.height
        let swapped = orientation >= 5
        let ow = swapped ? h : w, oh = swapped ? w : h
        guard let ctx = bitmapContext(width: ow, height: oh) else { return nil }
        // Transforms in CoreGraphics' y-up space mapping the stored image (drawn in 0,0,w,h) to the upright one.
        let fw = CGFloat(w), fh = CGFloat(h)
        let t: CGAffineTransform
        switch orientation {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: fw, ty: 0)            // mirrored horizontally
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: fw, ty: fh)          // rotated 180°
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: fh)            // mirrored vertically
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: fh, ty: fw)          // transposed
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: fw)            // rotated 90° CW to fix
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)              // transversed
        case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: fh, ty: 0)            // rotated 90° CCW to fix
        default: t = .identity
        }
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: fw, height: fh))
        return ctx.makeImage()
    }

    /// The file image after `UseExifOrientation`, `ImageCrop` and the color transform of `options` (Greyscale,
    /// ImageTint RGB or ColorMatrix, see `ImageOptions.processingMatrix`), plus the recipe identifying it. Flip,
    /// rotation and alpha are applied when drawing. Crop areas outside the image are transparent.
    static func prepared(atPath path: String, options: ImageOptions)
        -> (image: CGImage, generation: Int, recipe: Recipe)? {
        guard let e = entry(atPath: path) else { return nil }
        let orientedFlag = options.useExifOrientation && e.exifOrientation != 1
        let base = orientedFlag ? oriented(path, e) : e.image
        let iw = base.width, ih = base.height
        var crop: [Int]?
        if let c = options.crop {
            let r = c.rect(imageWidth: Double(iw), imageHeight: Double(ih))
            crop = [Int(r.x), Int(r.y), Int(r.width), Int(r.height)]
            if r.width < 1 || r.height < 1 { return nil }
            if crop == [0, 0, iw, ih] { crop = nil }
        }
        let matrix = options.processingMatrix
        let recipe = Recipe.prepared(oriented: orientedFlag, crop: crop, matrix: matrix)
        guard crop != nil || matrix != nil else { return (base, e.generation, recipe) }
        let key = DerivedKey(path: path, generation: e.generation, recipe: recipe)
        let rect = crop.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            ?? CGRect(x: 0, y: 0, width: iw, height: ih)
        let image = derived(key) {
            if matrix == nil, CGRect(x: 0, y: 0, width: iw, height: ih).contains(rect) {
                return base.cropping(to: rect)
            }
            return render(base, crop: rect, matrix: matrix)
        }
        guard let image else {
            // Too large to process (see maxDerivedPixels): an uncropped image is still drawn, without its color
            // transform, rather than not at all.
            return crop == nil ? (base, e.generation, .prepared(oriented: orientedFlag, crop: nil, matrix: nil)) : nil
        }
        return (image, e.generation, recipe)
    }

    /// Copies the `crop` rectangle (top-left pixel coordinates; may extend past the image) of `image` into a new
    /// bitmap and applies the color `matrix`.
    private static func render(_ image: CGImage, crop: CGRect, matrix: [Double]?) -> CGImage? {
        let w = Int(crop.width), h = Int(crop.height)
        guard w > 0, h > 0, w * h <= maxDerivedPixels, let ctx = bitmapContext(width: w, height: h) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -crop.minX, y: CGFloat(h) + crop.minY - CGFloat(image.height),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        if let matrix, let data = ctx.data {
            applyColorMatrix(matrix, data: data, width: w, height: h, rowBytes: ctx.bytesPerRow)
        }
        return ctx.makeImage()
    }

    /// Applies a 5×5 color matrix (rows = input R, G, B, A, offset; columns = output R, G, B, A) to premultiplied
    /// RGBA8 pixels: unpremultiply, multiply (vImage, 1/256 fixed point), premultiply.
    static func applyColorMatrix(_ m: [Double], data: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int) {
        guard m.count == 25 else { return }
        var buffer = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: rowBytes)
        let flags = vImage_Flags(kvImageNoFlags)
        vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, flags)
        var coefficients = [Int16](repeating: 0, count: 16)
        for i in 0..<4 {
            for j in 0..<4 {
                coefficients[i * 4 + j] = Int16(limit((m[i * 5 + j] * 256).rounded(), -32768, 32767))
            }
        }
        let bias = (0..<4).map { j in Int32(limit((m[20 + j] * 255 * 256).rounded(), -2e9, 2e9)) }
        var output = buffer
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 16)
        defer { scratch.deallocate() }
        output.data = scratch
        vImageMatrixMultiply_ARGB8888(&buffer, &output, coefficients, 256, nil, bias, flags)
        vImagePremultiplyData_RGBA8888(&output, &buffer, flags)
    }

    /// A premultiplied RGBA8 sRGB bitmap context (y up, rows top-down in memory, `width * 4` bytes per row).
    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, width * height <= maxDerivedPixels,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: Hit testing

    private static var alphaMasks: [DerivedKey: [UInt8]] = [:]
    private static let maxAlphaMaskPixels = 4_194_304

    /// Alpha (0…255) of pixel (x, y) (top-left origin) of the file image — EXIF-oriented when `oriented` — or nil
    /// when the file cannot be loaded or is too large to sample. Pixels outside the image are transparent.
    static func pixelAlpha(atPath path: String, x: Int, y: Int, oriented orientedFlag: Bool) -> Double? {
        guard let e = entry(atPath: path) else { return nil }
        let useOriented = orientedFlag && e.exifOrientation != 1
        let image = useOriented ? oriented(path, e) : e.image
        let w = image.width, h = image.height
        guard x >= 0, y >= 0, x < w, y < h else { return 0 }
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst
        else { return 255 }
        let key = DerivedKey(path: path, generation: e.generation, recipe: useOriented ? .oriented : .prepared(
            oriented: false, crop: nil, matrix: nil))
        if alphaMasks[key] == nil {
            guard w * h <= maxAlphaMaskPixels, let ctx = bitmapContext(width: w, height: h), let data = ctx.data
            else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            var mask = [UInt8](repeating: 0, count: w * h)
            for i in 0..<(w * h) { mask[i] = bytes[i * 4 + 3] }
            if alphaMasks.count >= 64 { alphaMasks.removeAll() }
            alphaMasks[key] = mask
        }
        guard let mask = alphaMasks[key], y * w + x < mask.count else { return nil }
        return Double(mask[y * w + x])
    }
}

/// `v` limited to `lo…hi` (NaN → `lo`), before converting to an integer type.
private func limit(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    v.isNaN ? lo : Swift.min(Swift.max(v, lo), hi)
}

// The app's skin hosts answer the optional image queries of the engine (EXIF orientation, pixel alpha).

extension SkinController: SkinImageQueries {
    func imageExifOrientation(atPath path: String) -> Int { Images.exifOrientation(atPath: path) }
    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        Images.pixelAlpha(atPath: path, x: x, y: y, oriented: exifOriented)
    }
}

extension RenderHost: SkinImageQueries {
    func imageExifOrientation(atPath path: String) -> Int { Images.exifOrientation(atPath: path) }
    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        Images.pixelAlpha(atPath: path, x: x, y: y, oriented: exifOriented)
    }
}
