import AppKit
import ImageIO

// What Chameleon needs to judge the part of the desktop picture that lies under a skin (`CropDesktop=Skin`, a Deskset
// extension): how macOS lays the picture on the screen, which frame of a dynamic picture it shows, where the picture is
// kept (macOS asks before an app reads some folders), and the picture itself, decoded once and kept small.

typealias ScreenDesktop = DesktopInputs.ScreenDesktop

// MARK: - Placement

/// How macOS lays a desktop picture on its screen (System Settings › Wallpaper: Fill Screen, Fit to Screen, Stretch to
/// Fill Screen, Center), from `NSWorkspace.desktopImageOptions(for:)`.
enum DesktopPlacement: String, Equatable {
    /// Scaled to cover the screen, the overflow cut off evenly (macOS's default).
    case fill
    /// Scaled to fit inside the screen, the fill color around it.
    case fit
    /// Scaled to the screen's size in both directions.
    case stretch
    /// At its own size (in points: pixels at the picture's resolution, 72 dpi when it gives none), centred.
    case center
    /// Like `fit`, but never scaled up.
    case shrink

    /// From the desktop picture options of a screen; no options (the usual case) is macOS's default, Fill Screen.
    init(options: [NSWorkspace.DesktopImageOptionKey: Any]?) {
        let scaling = (options?[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
        let clipping = (options?[.allowClipping] as? NSNumber)?.boolValue ?? true
        switch scaling {
        case .scaleAxesIndependently?: self = .stretch
        case .scaleNone?: self = .center
        case .scaleProportionallyDown?: self = .shrink
        case .scaleProportionallyUpOrDown?: self = clipping ? .fill : .fit
        default: self = .fill
        }
    }

    /// Where a picture of `picture` points is drawn on a screen of `screen` points: screen points, top-left origin.
    /// Zero for an empty picture or screen.
    func pictureRect(picture: CGSize, screen: CGSize) -> CGRect {
        guard picture.width > 0, picture.height > 0, screen.width > 0, screen.height > 0,
              picture.width.isFinite, picture.height.isFinite, screen.width.isFinite, screen.height.isFinite else {
            return .zero
        }
        let fitScale = min(screen.width / picture.width, screen.height / picture.height)
        let scale: CGFloat
        switch self {
        case .stretch: return CGRect(origin: .zero, size: screen)
        case .fill: scale = max(screen.width / picture.width, screen.height / picture.height)
        case .fit: scale = fitScale
        case .shrink: scale = min(1, fitScale)
        case .center: scale = 1
        }
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

// MARK: - Protected folders

/// Folders macOS guards with a Files & Folders prompt (System Settings › Privacy & Security › Files & Folders): an app
/// that opens a file in one of them makes macOS ask the person. Chameleon's `Type=Desktop` never reads a desktop picture
/// kept there, so a widget that samples the wallpaper never makes macOS ask.
enum ProtectedLocations {
    /// The guarded folders under the home folder: Desktop, Documents, Downloads, iCloud Drive and the cloud storage
    /// providers' folders.
    static func homeFolders(home: String) -> [String] {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        return ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { h + "/" + $0 }
    }

    /// Whether `path` names one of the guarded home folders or something in one, by its text alone
    /// (case-insensitive, as the Mac's disk is; `/System/Volumes/Data/Users/…` is the same folder as `/Users/…`).
    static func isInside(_ path: String, home: String) -> Bool {
        var p = path.lowercased()
        let data = "/system/volumes/data/"
        if p.hasPrefix(data) { p = "/" + p.dropFirst(data.count) }
        for folder in homeFolders(home: home).map({ $0.lowercased() }) where p == folder || p.hasPrefix(folder + "/") {
            return true
        }
        return false
    }

    /// Whether reading `path` would open a file in a guarded folder: the path itself, or where its symbolic links
    /// lead, in one of the home folders above or on a volume other than the startup disk (a mounted folder of
    /// `/Volumes`; macOS asks before an app reads a removable or network volume, and cannot be asked which kind it is
    /// without reading it). Links are followed one step at a time, and only outside the guarded folders (a link's own
    /// entry is read with `lstat` and `readlink`, which macOS does not guard; nothing inside a guarded folder is
    /// touched). At most 32 links; a loop counts as guarded.
    static func guards(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard path.hasPrefix("/") else { return false }
        // The home folder as the links below resolve it (a home reached through a link).
        let home = realHome(home)
        var pending = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var resolved: [String] = []
        var links = 0
        while !pending.isEmpty {
            let name = pending.removeFirst()
            if name == "." { continue }
            if name == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            let candidate = "/" + (resolved + [name]).joined(separator: "/")
            if isInside(candidate, home: home) { return true }
            var info = stat()
            let exists = lstat(candidate, &info) == 0
            if exists, info.st_mode & S_IFMT == S_IFLNK {
                links += 1
                guard links <= 32 else { return true }
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else {
                    resolved.append(name)
                    continue
                }
                if target.hasPrefix("/") { resolved = [] }
                pending = target.split(separator: "/", omittingEmptySubsequences: true).map(String.init) + pending
                continue
            }
            // A volume other than the startup disk: a mounted folder of /Volumes (the startup disk's entry there is a
            // link to /, followed above).
            if resolved.count == 1, resolved[0].lowercased() == "volumes", exists { return true }
            resolved.append(name)
        }
        return false
    }
}

extension ProtectedLocations {
    /// `home` with its links resolved (`realpath`: the home folder's own ancestors, none of them guarded), kept for the
    /// last one asked.
    static func realHome(_ home: String) -> String {
        if let known = resolvedHome.access({ $0 }), known.home == home { return known.real }
        var real = home
        if let resolved = realpath(home, nil) {
            real = String(cString: resolved)
            free(resolved)
        }
        resolvedHome.access { $0 = (home, real) }
        return real
    }

    private static let resolvedHome = Guarded<(home: String, real: String)?>(nil)
}

// MARK: - Dynamic desktop pictures

/// Dynamic desktop pictures (Sonoma, Mojave, the Big Sur set…) are HEIC files with several pictures and Apple's desktop
/// metadata: `apple_desktop:apr` (a light and a dark picture), `apple_desktop:h24` (by time of day) and
/// `apple_desktop:solar` (by the sun's position). Each is a property list in base 64 whose `l` and `d` entries (in
/// `ap` for the time-based ones) name the picture macOS shows in the light and in the dark appearance.
enum DynamicWallpaper {
    /// The light and dark pictures of a dynamic desktop picture; nil for any other picture.
    static func appearanceFrames(_ source: CGImageSource) -> (light: Int, dark: Int)? {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        for index in Set([0, primary]).sorted() {
            guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) else { continue }
            for key in ["apple_desktop:apr", "apple_desktop:h24", "apple_desktop:solar"] {
                guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, key as CFString),
                      let text = CGImageMetadataTagCopyValue(tag) as? String,
                      let frames = frames(fromBase64: text, count: count) else { continue }
                return frames
            }
        }
        return nil
    }

    /// The `l` / `d` entries of one metadata value (a binary or XML property list in base 64), when both name one of
    /// the file's `count` pictures.
    static func frames(fromBase64 text: String, count: Int) -> (light: Int, dark: Int)? {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let entries = (plist["ap"] as? [String: Any]) ?? plist
        func index(_ key: String) -> Int? {
            guard let n = entries[key] as? NSNumber else { return nil }
            let v = n.intValue
            return v >= 0 && v < count ? v : nil
        }
        guard let light = index("l"), let dark = index("d") else { return nil }
        return (light, dark)
    }

    /// The picture of `source` that macOS shows in the given appearance: the dynamic picture's light or dark one, else
    /// the file's primary picture.
    static func frame(of source: CGImageSource, dark: Bool) -> Int {
        if let frames = appearanceFrames(source) { return dark ? frames.dark : frames.light }
        return CGImageSourceGetPrimaryImageIndex(source)
    }
}

// MARK: - The decoded picture

/// Desktop pictures decoded small, shared by every skin: a wallpaper is decoded again only when its file, its date or
/// the picture shown (a dynamic picture's light or dark one) changes, not when a skin moves. Any thread; the decoding
/// runs on the caller's (a background queue).
final class WallpaperImages {
    struct Picture {
        /// At most `maxPixels` on its long side, upright.
        let image: CGImage
        /// The picture's size in points (its pixels at its resolution), upright: what `DesktopPlacement.center` shows.
        let pointSize: CGSize
        /// The picture of the file that was decoded.
        let frame: Int
    }

    static let shared = WallpaperImages()
    /// Enough for a luminance under a skin: a 110 pt strip on a 1512 pt screen still covers 28 rows.
    static let maxPixels = 384
    private static let kept = 3

    private let entries = Guarded<[(key: String, picture: Picture)]>([])
    private let framesByFile = Guarded<[String: (light: Int, dark: Int)?]>([:])

    /// The picture of `file` shown in the given appearance (a dynamic picture's light or dark one). `modified` is the
    /// file's modification date, part of what identifies a decoded picture.
    func picture(file: String, modified: TimeInterval, dark: Bool) -> Picture? {
        let url = URL(fileURLWithPath: file)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let frame = self.frame(of: source, file: file, modified: modified, dark: dark)
        let key = "\(file)|\(modified)|\(frame)"
        if let hit = entries.access({ list in list.first { $0.key == key }?.picture }) { return hit }
        guard let decoded = WallpaperImages.decode(source, frame: frame) else { return nil }
        entries.access { list in
            list.removeAll { $0.key == key }
            list.insert((key, decoded), at: 0)
            if list.count > WallpaperImages.kept { list.removeLast(list.count - WallpaperImages.kept) }
        }
        return decoded
    }

    /// Which picture of the file is shown in the appearance, worked out once per file and date.
    func frame(of source: CGImageSource, file: String, modified: TimeInterval, dark: Bool) -> Int {
        let key = "\(file)|\(modified)"
        let frames: (light: Int, dark: Int)?
        if let known = framesByFile.access({ $0[key] }) {
            frames = known
        } else {
            frames = DynamicWallpaper.appearanceFrames(source)
            framesByFile.access { map in
                if map.count > 16 { map.removeAll() }
                map[key] = .some(frames)
            }
        }
        if let frames { return dark ? frames.dark : frames.light }
        return CGImageSourceGetPrimaryImageIndex(source)
    }

    /// The picture of `file` shown in the given appearance, decoded at up to `maxPixels` and not kept: the render
    /// command draws it behind a skin.
    static func large(file: String, dark: Bool, maxPixels: Int) -> Picture? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source, frame: DynamicWallpaper.frame(of: source, dark: dark),
                      maxPixels: min(max(maxPixels, 64), 16_384))
    }

    static func decode(_ source: CGImageSource, frame: Int, maxPixels: Int = WallpaperImages.maxPixels) -> Picture? {
        guard frame >= 0, frame < CGImageSourceGetCount(source),
              let props = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any] else { return nil }
        var width = CGFloat((props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0)
        var height = CGFloat((props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0)
        var dpiX = CGFloat((props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72)
        var dpiY = CGFloat((props[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72)
        if !(dpiX > 0) { dpiX = 72 }
        if !(dpiY > 0) { dpiY = 72 }
        // Orientations 5–8 turn the picture a quarter.
        if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&width, &height)
            swap(&dpiX, &dpiY)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard width > 0, height > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, frame, options as CFDictionary),
              image.width > 0, image.height > 0 else { return nil }
        return Picture(image: image, pointSize: CGSize(width: width * 72 / dpiX, height: height * 72 / dpiY),
                       frame: frame)
    }

    /// Tests: forget every decoded picture.
    func removeAll() {
        entries.access { $0.removeAll() }
        framesByFile.access { $0.removeAll() }
    }

    /// Tests: how many pictures are kept decoded.
    var decodedCount: Int { entries.access { $0.count } }
}

// MARK: - Sampling under a skin

/// What a screen shows in a part of it: the fill color, and the desktop picture laid on it as macOS lays it.
enum DesktopSampler {
    /// The fill color around a picture that does not cover its screen, when macOS does not say (judgment).
    static let defaultFill = ChameleonColor(r: 0, g: 0, b: 0)

    /// The screen of `desktops` that shows most of `window` (skin coordinates: top-left origin at the primary screen's
    /// top-left corner), else the one nearest to it; nil without screens.
    static func screen(for window: CGRect, in desktops: [ScreenDesktop]) -> ScreenDesktop? {
        guard !desktops.isEmpty else { return nil }
        var best: (desktop: ScreenDesktop, area: CGFloat)?
        for d in desktops {
            let overlap = d.area.intersection(window)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (d, area) }
        }
        if let best { return best.desktop }
        func distance(_ d: ScreenDesktop) -> CGFloat {
            let dx = max(d.area.minX - window.midX, 0, window.midX - d.area.maxX)
            let dy = max(d.area.minY - window.midY, 0, window.midY - d.area.maxY)
            return dx * dx + dy * dy
        }
        return desktops.min { distance($0) < distance($1) }
    }

    /// The part of `desktop`'s screen that `window` covers, in screen points (top-left origin at the screen's corner);
    /// the whole screen when the window is off it.
    static func region(of window: CGRect, on desktop: ScreenDesktop) -> CGRect {
        let screen = CGRect(origin: .zero, size: desktop.area.size)
        let local = window.offsetBy(dx: -desktop.area.minX, dy: -desktop.area.minY).intersection(screen)
        guard !local.isNull, local.width >= 0.5, local.height >= 0.5 else { return screen }
        return local
    }

    /// Draws what the screen of `desktop` shows in `region` (screen points) into `context`, which is `size` pixels
    /// with CoreGraphics's bottom-left origin: the fill color, then the picture where macOS lays it. `picture` nil
    /// draws only the fill (a solid desktop).
    static func draw(_ picture: WallpaperImages.Picture?, desktop: ScreenDesktop, region: CGRect, into context: CGContext,
                     size: CGSize) {
        let fill = desktop.solid ?? desktop.fillColor ?? defaultFill
        context.setFillColor(CGColor(srgbRed: CGFloat(fill.r) / 255, green: CGFloat(fill.g) / 255,
                                     blue: CGFloat(fill.b) / 255, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        guard desktop.solid == nil, let picture, region.width > 0, region.height > 0 else { return }
        let placed = desktop.placement.pictureRect(picture: picture.pointSize, screen: desktop.area.size)
        guard placed.width > 0, placed.height > 0 else { return }
        let kx = size.width / region.width, ky = size.height / region.height
        let rect = CGRect(x: (placed.minX - region.minX) * kx, y: size.height - (placed.maxY - region.minY) * ky,
                          width: placed.width * kx, height: placed.height * ky)
        context.saveGState()
        context.interpolationQuality = .medium
        context.draw(picture.image, in: rect)
        context.restoreGState()
    }

    /// The pixels the screen of `desktop` shows under `window` (skin coordinates), at most `maxSide` on the long side;
    /// nil when there is nothing to draw.
    static func pixels(_ picture: WallpaperImages.Picture?, desktop: ScreenDesktop, window: CGRect,
                       maxSide: Int = 96) -> [ChameleonColor]? {
        guard picture != nil || desktop.solid != nil else { return nil }
        let region = self.region(of: window, on: desktop)
        guard region.width > 0, region.height > 0, region.width.isFinite, region.height.isFinite else { return nil }
        let k = min(1, CGFloat(maxSide) / max(region.width, region.height))
        let w = max(1, Int((region.width * k).rounded())), h = max(1, Int((region.height * k).rounded()))
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            draw(picture, desktop: desktop, region: region, into: ctx, size: CGSize(width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var result: [ChameleonColor] = []
        result.reserveCapacity(w * h)
        for i in stride(from: 0, to: data.count, by: 4) {
            // Opaque: the fill covers every pixel.
            result.append(ChameleonColor(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2])))
        }
        return result
    }
}
