import AppKit
import ImageIO

// The Studio's "Your Desktop" backdrop: the desktop picture of the screen the widget is on, laid out as macOS lays it
// out (`desktopImageOptions`: scaling, clipping, fill color), behind the widget where it really is.
//
// Reading a picture must never make macOS ask for permission. macOS guards the Desktop, Documents and Downloads
// folders, iCloud Drive and other cloud storage, other apps' data, the Photos library, and every other volume (external,
// removable, network): opening a file there — or even looking into a folder there — can put up a "would like to access
// files" prompt. So the path alone decides (`WallpaperPrivacy`), before anything is touched; a picture in such a place
// is not read, and the Studio shows the sample closest to the Mac's look instead, captioned "Close to your wallpaper".
// Links are followed one path component at a time, each looked at only after it was found safe.

/// Which places a desktop picture may be read from without macOS asking.
struct WallpaperPrivacy {
    /// The home folder (the real one: `NSHomeDirectory()` in the app, a made-up one in the tests).
    var home: String

    init(home: String = NSHomeDirectory()) {
        self.home = WallpaperPrivacy.normalized(home)
    }

    /// Folders of the home folder macOS guards (and everything under them).
    static let guardedHomeFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents",
                                     "Library/CloudStorage", "Library/Containers", "Library/Group Containers",
                                     "Library/Mail", "Library/Messages", "Library/Safari", "Library/Photos"]

    /// Places outside the home folder that are other volumes or network shares.
    static let guardedRoots = ["/Volumes", "/Network", "/net", "/private/var/automount"]

    /// Whether reading `path`, or anything under it, may make macOS ask for permission. Decided from the path alone.
    func isGuarded(_ path: String) -> Bool {
        let p = WallpaperPrivacy.normalized(path)
        let lower = p.lowercased()
        func under(_ folder: String) -> Bool {
            let f = folder.lowercased()
            return lower == f || lower.hasPrefix(f + "/")
        }
        if WallpaperPrivacy.guardedRoots.contains(where: under) { return true }
        if WallpaperPrivacy.guardedHomeFolders.contains(where: { under(home + "/" + $0) }) { return true }
        // Another user's home, and the Photos library wherever it is.
        if lower.hasPrefix("/users/"), !under(home), lower != "/users", !under("/Users/Shared") { return true }
        if p.split(separator: "/").contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) { return true }
        return false
    }

    /// `path` made absolute and plain, without touching the disk: `.` and `..` resolved, the data volume's firmlink
    /// (`/System/Volumes/Data/Users/…` is `/Users/…`) taken off, no trailing slash.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        var result = "/" + parts.joined(separator: "/")
        let data = "/System/Volumes/Data"
        if result.lowercased().hasPrefix(data.lowercased() + "/") { result = String(result.dropFirst(data.count)) }
        return result
    }
}

/// What the wallpaper code may ask of the file system. The app's reader touches the disk; the self-tests use one that
/// records every path it is asked about (none may be a guarded one).
protocol WallpaperFileReader: AnyObject {
    /// What is at `path`, without following a link there (`lstat`).
    func entry(atPath path: String) -> WallpaperFileEntry
    /// The names in the folder at `path`.
    func names(inFolder path: String) -> [String]
    /// The picture at `path`, at most `maxPixels` on its longer side, and how many pictures the file holds.
    func picture(atPath path: String, maxPixels: Int) -> (image: CGImage, count: Int)?
}

enum WallpaperFileEntry: Equatable {
    case missing
    case file
    case folder
    /// A symbolic link, with what it points to (as written in the link).
    case link(String)
}

/// The app's reader: the disk.
final class DiskWallpaperReader: WallpaperFileReader {
    static let shared = DiskWallpaperReader()

    func entry(atPath path: String) -> WallpaperFileEntry {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
            return target.isEmpty ? .missing : .link(target)
        case S_IFDIR: return .folder
        default: return .file
        }
    }

    func names(inFolder path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    func picture(atPath path: String, maxPixels: Int) -> (image: CGImage, count: Int)? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 64),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        return (image, count)
    }
}

/// How the Studio shows the desktop picture.
enum WallpaperFidelity: Equatable {
    /// The picture on the desktop now.
    case exact
    /// One of the pictures of a rotating folder, or a still of a dynamic or aerial wallpaper: macOS does not say which
    /// one shows now.
    case similar
    /// A sample in its place (the picture is in a guarded place, is a video, or cannot be read).
    case close
}

/// Where the desktop picture setting leads.
enum WallpaperResolution: Equatable {
    /// A picture file to read (a real path, links resolved); `similar`: a rotating folder's or an aerial's.
    case picture(String, similar: Bool)
    /// Nothing that can be read without asking, or nothing at all: a sample instead.
    case sample
}

enum WallpaperResolver {
    /// Extensions of wallpapers that move (aerials): a still cannot be read from them here.
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "hevc"]

    /// Follows the desktop picture setting `path` to a picture file: component by component (a guarded place ends it
    /// before anything there is looked at), through links (at most `maxLinks`), into a rotating folder (its first
    /// picture by name).
    static func resolve(_ path: String, privacy: WallpaperPrivacy, reader: WallpaperFileReader,
                        maxLinks: Int = 8) -> WallpaperResolution {
        guard !path.isEmpty, let real = realPath(path, privacy: privacy, reader: reader, maxLinks: maxLinks) else {
            return .sample
        }
        switch reader.entry(atPath: real) {
        case .file:
            let ext = (real as NSString).pathExtension.lowercased()
            if videoExtensions.contains(ext) { return .sample }
            let aerial = real.lowercased().contains("aerial") || real.lowercased().contains("idleassetsd")
            return .picture(real, similar: aerial)
        case .folder:
            let pictures = reader.names(inFolder: real).filter { !$0.hasPrefix(".") && DesktopPicture.isPictureFile($0) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for name in pictures {
                let candidate = (real as NSString).appendingPathComponent(name)
                guard let file = realPath(candidate, privacy: privacy, reader: reader, maxLinks: maxLinks),
                      reader.entry(atPath: file) == .file else { continue }
                return .picture(file, similar: true)
            }
            return .sample
        case .missing, .link:
            return .sample
        }
    }

    /// `path` with every link resolved, each component looked at only when it is not guarded; nil when it is (or
    /// leads into) a guarded place, does not exist, or has too many links.
    static func realPath(_ path: String, privacy: WallpaperPrivacy, reader: WallpaperFileReader,
                         maxLinks: Int) -> String? {
        var remaining = WallpaperPrivacy.normalized(path).split(separator: "/").map(String.init)
        var current = ""
        var links = 0
        while !remaining.isEmpty {
            let next = current + "/" + remaining.removeFirst()
            guard !privacy.isGuarded(next) else { return nil }
            switch reader.entry(atPath: next) {
            case .missing:
                return nil
            case .file, .folder:
                current = next
            case .link(let target):
                links += 1
                guard links <= maxLinks else { return nil }
                let base = target.hasPrefix("/") ? target : current + "/" + target
                remaining = WallpaperPrivacy.normalized(base).split(separator: "/").map(String.init) + remaining
                current = ""
            }
        }
        let result = current.isEmpty ? "/" : current
        return privacy.isGuarded(result) ? nil : result
    }
}

/// The desktop picture of one screen, as the Studio shows it.
struct StudioWallpaper {
    /// The picture (nil: `sample` stands in).
    var image: CGImage?
    var fidelity: WallpaperFidelity
    /// The sample used when there is no picture: the one closest to the Mac's look.
    var sample: StudioSample
    /// How macOS lays the picture out on the screen.
    var scaling: NSImageScaling
    var allowsClipping: Bool
    /// The color around a picture that does not fill the screen.
    var fillColor: CGColor
    /// The screen's frame (global coordinates, points) and backing scale.
    var screenFrame: CGRect
    var screenScale: CGFloat

    /// Where the picture goes on the screen (screen coordinates from its bottom-left corner, points).
    var pictureRect: CGRect? {
        guard let image else { return nil }
        let pixels = CGSize(width: image.width, height: image.height)
        return WallpaperLayout.rect(picturePixels: pixels, pictureScale: screenScale, screen: screenFrame.size,
                                    scaling: scaling, allowsClipping: allowsClipping)
    }
}

enum WallpaperLayout {
    /// Where macOS puts a picture of `picturePixels` on a screen of `screen` points, for its desktop options:
    /// "Fill Screen" (proportional, clipped), "Fit to Screen" (proportional, not clipped: the fill color around),
    /// "Stretch to Fill Screen" (axes independently), "Centre" (actual size), and proportional down only.
    static func rect(picturePixels: CGSize, pictureScale: CGFloat, screen: CGSize, scaling: NSImageScaling,
                     allowsClipping: Bool) -> CGRect {
        let full = CGRect(origin: .zero, size: screen)
        guard picturePixels.width > 0, picturePixels.height > 0, screen.width > 0, screen.height > 0 else { return full }
        let natural = CGSize(width: picturePixels.width / max(pictureScale, 1),
                             height: picturePixels.height / max(pictureScale, 1))
        func centred(_ size: CGSize) -> CGRect {
            CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2, width: size.width,
                   height: size.height)
        }
        let sx = screen.width / picturePixels.width, sy = screen.height / picturePixels.height
        switch scaling {
        case .scaleAxesIndependently:
            return full
        case .scaleNone:
            return centred(natural)
        case .scaleProportionallyDown:
            let f = min(1, min(screen.width / natural.width, screen.height / natural.height))
            return centred(CGSize(width: natural.width * f, height: natural.height * f))
        default:
            let f = allowsClipping ? max(sx, sy) : min(sx, sy)
            return centred(CGSize(width: picturePixels.width * f, height: picturePixels.height * f))
        }
    }
}

/// A screen's desktop picture setting, as `NSWorkspace` gives it.
struct WallpaperSetting {
    var path: String
    var scaling: NSImageScaling = .scaleProportionallyUpOrDown
    var allowsClipping = true
    var fillColor: CGColor?
    var screenFrame: CGRect
    var screenScale: CGFloat

    /// `screen`'s setting (main thread; asking does not read the picture).
    static func of(_ screen: NSScreen) -> WallpaperSetting {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
            ?? .scaleProportionallyUpOrDown
        return WallpaperSetting(path: NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? "", scaling: scaling,
                                allowsClipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? true,
                                fillColor: (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)?.cgColor,
                                screenFrame: screen.frame, screenScale: screen.backingScaleFactor)
    }
}

/// Reads the desktop pictures for the Studio: the setting on the main thread (`NSWorkspace`), the file on a
/// background queue, the result back on the main thread. One picture per setting and size is kept.
final class WallpaperSource {
    var privacy = WallpaperPrivacy()
    var reader: WallpaperFileReader = DiskWallpaperReader.shared
    /// Where the work runs (the tests run it at once).
    var queue: DispatchQueue? = DispatchQueue(label: "deskset.studio.wallpaper", qos: .userInitiated)
    /// How a screen's setting is asked for (the self-tests give their own).
    var setting: (NSScreen) -> WallpaperSetting = WallpaperSetting.of
    /// How many times a desktop picture was asked for (the headless Studio never asks).
    private(set) var requests = 0

    private struct Key: Hashable {
        var path: String
        var maxPixels: Int
    }
    private var cache: [Key: (image: CGImage?, fidelity: WallpaperFidelity)] = [:]
    private var pending: Set<Key> = []

    /// The desktop picture of `screen` for a Mac look (`dark`), or nil while it is being read (`ready` is called on
    /// the main thread once it is).
    func wallpaper(for screen: NSScreen, dark: Bool, ready: @escaping () -> Void) -> StudioWallpaper? {
        wallpaper(for: setting(screen), dark: dark, ready: ready)
    }

    /// The desktop picture of a screen whose setting is `setting`.
    func wallpaper(for setting: WallpaperSetting, dark: Bool, ready: @escaping () -> Void) -> StudioWallpaper? {
        dispatchPrecondition(condition: .onQueue(.main))
        requests += 1
        let fill = setting.fillColor ?? CGColor(srgbRed: 0.2, green: 0.2, blue: 0.22, alpha: 1)
        let maxPixels = Int(max(setting.screenFrame.width, setting.screenFrame.height) * setting.screenScale)
        var result = StudioWallpaper(image: nil, fidelity: .close, sample: dark ? .dusk : .bright,
                                     scaling: setting.scaling, allowsClipping: setting.allowsClipping, fillColor: fill,
                                     screenFrame: setting.screenFrame, screenScale: setting.screenScale)
        let key = Key(path: setting.path, maxPixels: maxPixels)
        if let known = cache[key] {
            result.image = known.image
            result.fidelity = known.image == nil ? .close : known.fidelity
            return result
        }
        load(key, then: ready)
        // Read at once (no queue): the answer is there already.
        if let known = cache[key] {
            result.image = known.image
            result.fidelity = known.image == nil ? .close : known.fidelity
            return result
        }
        return nil
    }

    /// Reads `key`'s picture (off the main thread when there is a queue) and keeps it.
    private func load(_ key: Key, then ready: @escaping () -> Void) {
        guard !pending.contains(key) else { return }
        pending.insert(key)
        let privacy = self.privacy, reader = self.reader
        let work = {
            var found: (image: CGImage?, fidelity: WallpaperFidelity) = (nil, .close)
            if case .picture(let file, let similar) = WallpaperResolver.resolve(key.path, privacy: privacy,
                                                                                 reader: reader),
               let picture = reader.picture(atPath: file, maxPixels: key.maxPixels) {
                // A dynamic wallpaper holds several pictures; which one shows now is macOS's secret.
                found = (picture.image, similar || picture.count > 1 ? .similar : .exact)
            }
            let finish = { [weak self] in
                guard let self else { return }
                self.pending.remove(key)
                self.cache[key] = found
                ready()
            }
            if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
        }
        if let queue { queue.async(execute: work) } else { work() }
    }

    /// Forgets what was read (the desktop picture changed).
    func forget() { cache = [:] }
}
