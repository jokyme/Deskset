import Accelerate
import AppKit
import ImageIO
import DesksetCore
import DesksetDraw

/// Decoded image files and images derived from them (EXIF-oriented, cropped, color-transformed, flattened,
/// strip frames, masks), all cached. A file is re-checked with one `stat` per lookup and reloaded — and its
/// derived images dropped — when its modification time, size or inode changes; decoding happens once per
/// version of the file.
///
/// Formats: whatever ImageIO decodes — the manual's .png, .jpg, .bmp, .gif (first frame only, "no animation
/// supported"), .tif, .webp and .ico (the largest icon in the file).
///
/// A file can also be decoded at a smaller size (`drawnPath(_:maxPixelSide:)`, the Image meter's `MacDecodeSize=Drawn`;
/// Deskset extension): its own entry, keyed by a path of its own, with the density of its pixels per point of the file
/// — a 48 MP photo drawn in a 360 pt frame costs a few MB rather than 186. The engine's sizes stay the file's. Large
/// files answer `size(atPath:)` and `exifOrientation(atPath:)` from their header, so asking for them never decodes the
/// whole file.
///
/// SF Symbols (`sf:` paths, `MacSymbol`; Deskset extension) are kept here too: rendered by `SymbolImages` rather than
/// decoded, never checked on disk, and at a density of their own — an entry's `density` is its pixels per point
/// (1 for files: "1 image pixel = 1 point"). Sizes the engine sees (`size(atPath:)`), crop rectangles and hit tests
/// are in points; `PreparedImage` draws with the density.
///
/// Thread-safe (docs/skin-threading.md §4.4): skins measure and draw on threads of their own, and the caches stay
/// shared by all of them (decoded photos are big, and two skins showing the same file share one copy).
/// - One lock, `condition`, guards every cache; the lookups and inserts under it are short.
/// - Decoding a file, making a derived image and sampling an alpha mask happen outside it, so a skin decoding a large
///   photo does not hold up the others.
/// - Each of these is made by one thread at a time: whoever needs a file (or derived image, or mask) that another
///   thread is making right now waits for that one (`inFlight`) instead of decoding it a second time. The maker never
///   waits for anything while it makes it.
/// - A result made from a version of the file that was replaced (or purged) meanwhile is handed to its caller but not
///   kept.
enum Images {
    /// One backend for the lifetime of the shared cache: a cached path must never mix platform renderers.
    private static let symbolRasterizer: any SymbolRasterizing = AppSymbolRasterizer()

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

    /// Pixels per point of an image, per axis (files: 1).
    struct Density: Hashable {
        var x: CGFloat
        var y: CGFloat

        static let one = Density(x: 1, y: 1)
    }

    /// One decoded version of a file (or one rendered symbol). Immutable apart from `lastUse`, which is touched under
    /// the lock.
    final class Entry {
        let image: CGImage
        let exifOrientation: Int
        let generation: Int
        /// Pixels per point (1 for files).
        let density: Density
        /// nil for a symbol.
        fileprivate let stamp: FileStamp?
        fileprivate let cost: Int
        fileprivate var lastUse: TimeInterval

        fileprivate init(image: CGImage, exifOrientation: Int, generation: Int, stamp: FileStamp?, now: TimeInterval,
                         density: Density = .one) {
            self.image = image
            self.exifOrientation = exifOrientation
            self.generation = generation
            self.stamp = stamp
            self.density = density
            cost = image.bytesPerRow * image.height
            lastUse = now
        }

        /// Size in points (the engine's size of the image).
        var pointSize: (width: Double, height: Double) {
            (Double(image.width) / Double(density.x), Double(image.height) / Double(density.y))
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

    /// Guards everything below that is `static var`, and `Entry.lastUse` / `DerivedEntry.lastUse`. Its condition
    /// wakes the threads waiting for something another thread was making (`inFlight`).
    private static let condition = NSCondition()
    private static var entries: [String: Entry] = [:]
    private static var entriesCost = 0
    private static var failures: [String: FileStamp] = [:]
    /// Symbol paths macOS has no symbol for (or too large to render).
    private static var symbolFailures: Set<String> = []
    private static var nextGeneration = 1

    /// What one thread is making right now, outside the lock: others that need the same wait for it.
    private enum Work: Hashable {
        case file(String)
        case derived(DerivedKey)
        case alphaMask(DerivedKey)
    }

    private static var inFlight: Set<Work> = []
    /// Counts `purge()`s: what was being made when the caches were purged is not kept.
    private static var purges = 0
    private static var waiting = 0
    private static var decodeHook: ((String) -> Void)?

    /// Threads waiting right now for something another thread is making (self-tests).
    static var waitingCount: Int { locked { waiting } }
    /// The image decoded for `path` now (a file's path or a `drawnPath`), without decoding anything (self-tests).
    static func cachedImage(_ path: String) -> CGImage? { locked { entries[path]?.image } }
    /// Called on the decoding thread, outside the lock, just before a file is decoded (self-tests: counts decodes, and
    /// holds one up until other threads wait for it).
    static var willDecode: ((String) -> Void)? {
        get { locked { decodeHook } }
        set { locked { decodeHook = newValue } }
    }

    private static func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }

    /// Waits (with the lock held) for another thread to finish `work`; true when it was in flight at all.
    private static func waitIfInFlight(_ work: Work) -> Bool {
        guard inFlight.contains(work) else { return false }
        waiting += 1
        while inFlight.contains(work) { condition.wait() }
        waiting -= 1
        return true
    }

    /// Marks `work` done (with the lock held) and wakes whoever waits for it.
    private static func finish(_ work: Work) {
        inFlight.remove(work)
        condition.broadcast()
    }

    // MARK: Files

    /// The current decoded version of the file, or nil when it is missing or cannot be decoded. Any thread.
    static func entry(atPath path: String) -> Entry? {
        if MacSymbol.isSymbolPath(path) { return symbolEntry(path) }
        // A file decoded at a smaller size is cached under its own path, and checked and decoded as the file.
        let request = decodeRequest(path)
        let file = request?.file ?? path
        while true {
            let stamp = lookupStamp(file)
            condition.lock()
            guard let stamp else {
                removeEntry(path)
                failures[path] = nil
                condition.unlock()
                return nil
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let e = entries[path], e.stamp == stamp {
                e.lastUse = now
                condition.unlock()
                return e
            }
            if failures[path] == stamp {
                condition.unlock()
                return nil
            }
            // Another thread is decoding this file: wait for it, then look again (the file may have changed since).
            if waitIfInFlight(.file(path)) {
                condition.unlock()
                continue
            }
            inFlight.insert(.file(path))
            removeEntry(path)
            let purged = purges
            let hook = decodeHook
            condition.unlock()

            hook?(file)
            let decoded = decode(file, maxPixelSide: request?.side)

            condition.lock()
            defer { condition.unlock() }
            finish(.file(path))
            // Purged meanwhile (Refresh All): hand the result over, keep nothing.
            let keep = purges == purged
            guard let decoded else {
                if keep {
                    // Bounded: a measure can name a new undecodable file on every update.
                    if failures.count >= 1024 { failures.removeAll() }
                    failures[path] = stamp
                }
                return nil
            }
            let e = Entry(image: decoded.image, exifOrientation: decoded.orientation, generation: nextGeneration,
                          stamp: stamp, now: now, density: decoded.density)
            nextGeneration += 1
            guard keep else { return e }
            failures[path] = nil
            entries[path] = e
            entriesCost += e.cost
            if entriesCost > entryCostLimit { evictEntries(now: now) }
            return e
        }
    }

    // MARK: Files a drawing used

    /// The files looked up while a drawing ran (`recordingFiles`), each as it was then (missing ones too). A picture of
    /// that drawing stays right while they stay as they were (`filesUnchanged`): a file replaced on disk shows in the
    /// next drawing that looks it up, and a kept picture that does not look anything up must not miss that.
    struct UsedFiles: Equatable {
        fileprivate var stamps: [String: FileStamp?] = [:]
        fileprivate var purges = 0
        /// The files (paths on disk) looked up.
        var paths: [String] { stamps.keys.sorted() }
    }

    private final class FileRecorder {
        var used = UsedFiles()
    }

    private static let recorderKey = "DesksetImages.FileRecorder"

    /// Runs `body`, recording every file it looks up on this thread. A recording inside another one is also part of
    /// the outer one.
    static func recordingFiles(_ body: () -> Void) -> UsedFiles {
        let dictionary = Thread.current.threadDictionary
        let outer = dictionary[recorderKey] as? FileRecorder
        let recorder = FileRecorder()
        recorder.used.purges = locked { purges }
        dictionary[recorderKey] = recorder
        body()
        dictionary[recorderKey] = outer
        if let outer {
            for (path, stamp) in recorder.used.stamps where outer.used.stamps.index(forKey: path) == nil {
                outer.used.stamps[path] = stamp
            }
        }
        return recorder.used
    }

    /// Whether every file in `used` is as it was when it was looked up, and the caches were not purged since (one
    /// `stat` per file, as a drawing's own lookups cost). Any thread.
    static func filesUnchanged(_ used: UsedFiles) -> Bool {
        guard locked({ purges }) == used.purges else { return false }
        return used.stamps.allSatisfy { FileStamp(path: $0.key) == $0.value }
    }

    /// The file's stamp now, for a lookup: a recording on this thread (`recordingFiles`) keeps the first one it sees.
    private static func lookupStamp(_ path: String) -> FileStamp? {
        let stamp = FileStamp(path: path)
        if let recorder = Thread.current.threadDictionary[recorderKey] as? FileRecorder,
           recorder.used.stamps.index(forKey: path) == nil {
            recorder.used.stamps[path] = .some(stamp)
        }
        return stamp
    }

    /// The rendered symbol of a symbol path (`MacSymbol.path`), nil when macOS has no such symbol. Rendered once, by one
    /// thread at a time, like a file is decoded; kept until evicted or purged (a symbol never changes).
    private static func symbolEntry(_ path: String) -> Entry? {
        while true {
            condition.lock()
            let now = ProcessInfo.processInfo.systemUptime
            if let e = entries[path] {
                e.lastUse = now
                condition.unlock()
                return e
            }
            if symbolFailures.contains(path) {
                condition.unlock()
                return nil
            }
            if waitIfInFlight(.file(path)) {
                condition.unlock()
                continue
            }
            inFlight.insert(.file(path))
            let purged = purges
            condition.unlock()

            let rendered = MacSymbol(path: path).flatMap(symbolRasterizer.render)

            condition.lock()
            defer { condition.unlock() }
            finish(.file(path))
            let keep = purges == purged
            guard let rendered else {
                if keep {
                    if symbolFailures.count >= 1024 { symbolFailures.removeAll() }
                    symbolFailures.insert(path)
                }
                return nil
            }
            let density = Density(x: CGFloat(rendered.image.width) / rendered.pointSize.width,
                                  y: CGFloat(rendered.image.height) / rendered.pointSize.height)
            let e = Entry(image: rendered.image, exifOrientation: 1, generation: nextGeneration, stamp: nil, now: now,
                          density: density)
            nextGeneration += 1
            guard keep else { return e }
            entries[path] = e
            entriesCost += e.cost
            if entriesCost > entryCostLimit { evictEntries(now: now) }
            return e
        }
    }

    /// Whether `key` was made from the file as it is cached now (with the lock held): a derived image or mask made
    /// from a version replaced or purged meanwhile is not kept (nothing would ever ask for it again).
    private static func isCurrent(_ key: DerivedKey) -> Bool {
        entries[key.path]?.generation == key.generation
    }

    /// Forgets the decoded file and everything derived from it (with the lock held).
    private static func removeEntry(_ path: String) {
        guard let old = entries.removeValue(forKey: path) else { return }
        entriesCost -= old.cost
        dropDerived(path)
    }

    /// Drops least recently used decoded files until the cache is back under 3/4 of its budget, keeping files used
    /// within `entryKeepAlive` (with the lock held).
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

    /// Size in pixels (Rainmeter works in pixels; 1 image pixel = 1 point), as stored in the file. A symbol's size in
    /// points.
    static func size(atPath path: String) -> (width: Double, height: Double)? {
        if let h = largeHeader(path) { return (Double(h.width), Double(h.height)) }
        return entry(atPath: path)?.pointSize
    }

    /// EXIF orientation (1…8) of the file; 1 when it has none.
    static func exifOrientation(atPath path: String) -> Int {
        if let h = largeHeader(path) { return h.orientation }
        return entry(atPath: path)?.exifOrientation ?? 1
    }

    /// Refresh All: every file is decoded again (a skin author may have edited it). What another thread is decoding or
    /// making right now is handed to its caller but not kept. Any thread.
    static func purge() {
        condition.lock()
        defer { condition.unlock() }
        purges += 1
        entries.removeAll()
        headers.removeAll()
        entriesCost = 0
        failures.removeAll()
        symbolFailures.removeAll()
        derived.removeAll()
        derivedFailures.removeAll()
        derivedCost = 0
        alphaMasks.removeAll()
    }

    /// Decodes the file: at most `maxDecodeSide` pixels per side, or at most `maxPixelSide` when that is smaller (then
    /// the density is the decoded pixels per pixel of the full decode, so sizes in points stay the file's).
    private static func decode(_ path: String, maxPixelSide: Int? = nil)
        -> (image: CGImage, orientation: Int, density: Density)? {
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
        let limit = min(maxPixelSide ?? maxDecodeSide, maxDecodeSide)
        let image: CGImage?
        if max(w, h) > limit {
            image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, index,
                                                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image, image.width > 0, image.height > 0 else { return nil }
        var density = Density.one
        if maxPixelSide != nil, w > 0, h > 0 {
            // The full decode's size (the file's, or its downsampled size past maxDecodeSide) is the size in points.
            let full = fullDecodeSize(width: w, height: h)
            density = Density(x: CGFloat(image.width) / CGFloat(full.width),
                              y: CGFloat(image.height) / CGFloat(full.height))
        }
        return (image, (1...8).contains(orientation) ? orientation : 1, density)
    }

    /// The pixel size a full decode gives a file of `width` × `height` (downsampled past `maxDecodeSide`).
    private static func fullDecodeSize(width w: Int, height h: Int) -> (width: Int, height: Int) {
        guard max(w, h) > maxDecodeSide else { return (w, h) }
        let s = Double(maxDecodeSide) / Double(max(w, h))
        return (max(1, Int((Double(w) * s).rounded())), max(1, Int((Double(h) * s).rounded())))
    }

    // MARK: Decoding at the drawn size

    /// The marker between a file's path and the pixel size it is decoded at (no file path contains a NUL).
    private static let decodeMarker = "\u{0}decode="

    /// A path that decodes the file at `path` with at most `maxPixelSide` pixels on its longer side, cached apart
    /// from the full decode; every query of this type takes it (sizes stay the file's, in points). `path` itself when
    /// that is no smaller than a full decode, or for a symbol.
    static func drawnPath(_ path: String, maxPixelSide: Int) -> String {
        guard !MacSymbol.isSymbolPath(path), decodeRequest(path) == nil, maxPixelSide > 0,
              let header = header(atPath: path), maxPixelSide < max(header.width, header.height),
              maxPixelSide < maxDecodeSide else { return path }
        return path + decodeMarker + String(maxPixelSide)
    }

    /// The file and the size of a `drawnPath`; nil for any other path.
    static func decodeRequest(_ path: String) -> (file: String, side: Int)? {
        guard let r = path.range(of: decodeMarker), let side = Int(path[r.upperBound...]), side > 0 else { return nil }
        return (String(path[..<r.lowerBound]), side)
    }

    // MARK: File headers

    /// What a file's header says, read without decoding it.
    struct Header {
        /// Pixels (of the image a full decode uses: the largest in an icon file).
        let width: Int
        let height: Int
        let orientation: Int
        /// Whether a full decode gives exactly `width` × `height`: not an icon file (whose largest image is decoded),
        /// within `maxDecodeSide`.
        let exact: Bool
    }

    private static var headers: [String: (stamp: FileStamp, header: Header)] = [:]
    /// Files with at least this many pixels answer `size(atPath:)` and `exifOrientation(atPath:)` from their header
    /// until they are decoded (smaller files are decoded, as they always were: that also finds files that cannot be).
    static let headerPixels = 4_000_000

    /// The file's header, cached per version of the file; nil when it is missing or unreadable. Any thread.
    static func header(atPath path: String) -> Header? {
        guard let stamp = lookupStamp(path) else { return nil }
        if let h = locked({ headers[path] }), h.stamp == stamp { return h.header }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? Int) ?? 1
        let type = (CGImageSourceGetType(source) as String?) ?? ""
        let icon = type == "com.microsoft.ico" || type == "com.microsoft.cur" || type == "com.apple.icns"
        let header = Header(width: w, height: h, orientation: (1...8).contains(o) ? o : 1,
                            exact: !icon && max(w, h) <= maxDecodeSide && w * h <= maxSourcePixels)
        locked {
            if headers.count >= 1024 { headers.removeAll() }
            headers[path] = (stamp, header)
        }
        return header
    }

    /// The header of a large file that is not decoded now (nil otherwise: ask its entry).
    private static func largeHeader(_ path: String) -> Header? {
        guard !MacSymbol.isSymbolPath(path) else { return nil }
        let request = decodeRequest(path)
        let file = request?.file ?? path
        if request == nil, let stamp = lookupStamp(file),
           locked({ entries[path].map { $0.stamp == stamp } ?? false }) { return nil }
        guard let h = header(atPath: file), h.exact, h.width * h.height >= headerPixels else { return nil }
        return h
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

    /// Cached derived image for `key`, made with `make` on a miss. A failed `make` is remembered too. Any thread;
    /// `make` runs outside the lock, and must not ask for `key` itself.
    static func derived(_ key: DerivedKey, _ make: () -> CGImage?) -> CGImage? {
        condition.lock()
        useCounter += 1
        repeat {
            if let hit = derived[key] {
                hit.lastUse = useCounter
                condition.unlock()
                return hit.image
            }
            if derivedFailures.contains(key) {
                condition.unlock()
                return nil
            }
        } while waitIfInFlight(.derived(key))
        inFlight.insert(.derived(key))
        condition.unlock()

        let image = make()

        condition.lock()
        defer { condition.unlock() }
        finish(.derived(key))
        guard isCurrent(key) else { return image }
        guard let image else {
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

    /// With the lock held.
    private static func evict() {
        let byAge = derived.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, entry) in byAge {
            guard derivedCost > derivedCostLimit / 2 || derived.count > derivedCountLimit / 2 else { break }
            derived[key] = nil
            derivedCost -= entry.cost
        }
    }

    /// With the lock held.
    private static func dropDerived(_ path: String) {
        for (key, entry) in derived where key.path == path {
            derived[key] = nil
            derivedCost -= entry.cost
        }
        derivedFailures = derivedFailures.filter { $0.path != path }
        alphaMasks = alphaMasks.filter { $0.key.path != path }
    }

    /// The file image with its EXIF orientation applied (the stored image when the orientation is 1). Any thread.
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
    /// ImageTint RGB or ColorMatrix, see `ImageOptions.processingMatrix`), plus the recipe identifying it and its
    /// density. Flip, rotation and alpha are applied when drawing. Crop areas outside the image are transparent.
    /// ImageCrop is in points (pixels of a file).
    static func prepared(atPath path: String, options: ImageOptions)
        -> (image: CGImage, generation: Int, recipe: Recipe, density: Density)? {
        guard let e = entry(atPath: path) else { return nil }
        let orientedFlag = options.useExifOrientation && e.exifOrientation != 1
        let base = orientedFlag ? oriented(path, e) : e.image
        let iw = base.width, ih = base.height
        let d = e.density
        var crop: [Int]?
        if let c = options.crop {
            let r = c.rect(imageWidth: Double(iw) / Double(d.x), imageHeight: Double(ih) / Double(d.y))
            if d == .one {
                crop = [Int(r.x), Int(r.y), Int(r.width), Int(r.height)]
            } else {
                func px(_ v: Double, _ scale: CGFloat) -> Int { Int((v * Double(scale)).rounded()) }
                crop = [px(r.x, d.x), px(r.y, d.y), px(r.width, d.x), px(r.height, d.y)]
            }
            if r.width < 1 || r.height < 1 { return nil }
            if crop == [0, 0, iw, ih] { crop = nil }
        }
        let matrix = options.processingMatrix
        let recipe = Recipe.prepared(oriented: orientedFlag, crop: crop, matrix: matrix)
        guard crop != nil || matrix != nil else { return (base, e.generation, recipe, d) }
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
            guard crop == nil else { return nil }
            return (base, e.generation, .prepared(oriented: orientedFlag, crop: nil, matrix: nil), d)
        }
        return (image, e.generation, recipe, d)
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
    /// when the file cannot be loaded or is too large to sample. Pixels outside the image are transparent. (x, y) are
    /// points: for a symbol, the pixel under that point.
    static func pixelAlpha(atPath path: String, x px: Int, y py: Int, oriented orientedFlag: Bool) -> Double? {
        guard let e = entry(atPath: path) else { return nil }
        var x = px, y = py
        if e.density != .one {
            x = Int(((Double(px) + 0.5) * Double(e.density.x)).rounded(.down))
            y = Int(((Double(py) + 0.5) * Double(e.density.y)).rounded(.down))
        }
        let useOriented = orientedFlag && e.exifOrientation != 1
        let image = useOriented ? oriented(path, e) : e.image
        let w = image.width, h = image.height
        guard x >= 0, y >= 0, x < w, y < h else { return 0 }
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst
        else { return 255 }
        let key = DerivedKey(path: path, generation: e.generation, recipe: useOriented ? .oriented : .prepared(
            oriented: false, crop: nil, matrix: nil))
        guard let mask = alphaMask(key, of: image), y * w + x < mask.count else { return nil }
        return Double(mask[y * w + x])
    }

    /// The alpha channel of `image` (the file image `key` names), sampled once and cached; nil when the image is too
    /// large to sample. Sampled outside the lock, by one thread at a time.
    private static func alphaMask(_ key: DerivedKey, of image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w * h <= maxAlphaMaskPixels else { return nil }
        condition.lock()
        repeat {
            if let mask = alphaMasks[key] {
                condition.unlock()
                return mask
            }
        } while waitIfInFlight(.alphaMask(key))
        inFlight.insert(.alphaMask(key))
        condition.unlock()

        var mask: [UInt8]?
        if let ctx = bitmapContext(width: w, height: h), let data = ctx.data {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            var alpha = [UInt8](repeating: 0, count: w * h)
            for i in 0..<(w * h) { alpha[i] = bytes[i * 4 + 3] }
            mask = alpha
        }

        condition.lock()
        defer { condition.unlock() }
        finish(.alphaMask(key))
        if let mask, isCurrent(key) {
            if alphaMasks.count >= 64 { alphaMasks.removeAll() }
            alphaMasks[key] = mask
        }
        return mask
    }
}

/// `v` limited to `lo…hi` (NaN → `lo`), before converting to an integer type.
private func limit(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    v.isNaN ? lo : Swift.min(Swift.max(v, lo), hi)
}

// The app's skin hosts answer the optional image queries of the engine (EXIF orientation, pixel alpha).

extension RenderHost: SkinImageQueries {
    func imageExifOrientation(atPath path: String) -> Int { Images.exifOrientation(atPath: path) }
    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        Images.pixelAlpha(atPath: path, x: x, y: y, oriented: exifOriented)
    }
}
