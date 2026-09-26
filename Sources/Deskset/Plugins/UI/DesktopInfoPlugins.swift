import AppKit
import ImageIO
import DesksetCore

// Third-party plugins about the desktop and the focused app, from their public usage documentation only:
//   Chameleon      — github.com/socks-the-fox/Chameleon (Readme.md)
//   IsFullScreen   — "IsFullScreen 3.0" usage post on the Rainmeter forums (prose only)
//   GetActiveTitle — github.com/jsmorley/GetActiveTitle (description) and its forum announcement
//   SysColor       — github.com/brianferguson/SysColor.dll (README.md)

// MARK: - Chameleon

/// An sRGB color with 0…255 channels.
struct ChameleonColor: Equatable, Hashable {
    var r: Int
    var g: Int
    var b: Int

    var hex: String { String(format: "%02X%02X%02X", r, g, b) }
    var decimal: String { "\(r),\(g),\(b)" }

    /// Relative luminance 0…1 (sRGB, WCAG).
    var luminance: Double {
        func lin(_ v: Int) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func contrast(with other: ChameleonColor) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func distance(to o: ChameleonColor) -> Double {
        let dr = Double(r - o.r), dg = Double(g - o.g), db = Double(b - o.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// `t` of the way towards `o`.
    func mixed(with o: ChameleonColor, _ t: Double) -> ChameleonColor {
        func m(_ a: Int, _ b: Int) -> Int { Int((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        return ChameleonColor(r: m(r, o.r), g: m(g, o.g), b: m(b, o.b))
    }

    static let black = ChameleonColor(r: 0, g: 0, b: 0)
    static let white = ChameleonColor(r: 255, g: 255, b: 255)

    init(r: Int, g: Int, b: Int) {
        self.r = min(max(r, 0), 255)
        self.g = min(max(g, 0), 255)
        self.b = min(max(b, 0), 255)
    }

    /// `RRGGBB` (Chameleon's Fallback options are hex without alpha).
    init?(hex: String) {
        var t = hex.muiTrimmed
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count >= 6, let v = UInt32(t.prefix(6), radix: 16) else { return nil }
        self.init(r: Int(v >> 16 & 0xFF), g: Int(v >> 8 & 0xFF), b: Int(v & 0xFF))
    }
}

/// Colors picked from an image. Judgment: Chameleon documents only what the colors mean, not how they are chosen;
/// this is an original method: a coarse color histogram merged into up to 8 clusters; Background1 = the largest
/// cluster, Background2 = the next distinct one; Foreground1/2 = the clusters that contrast most with Background1
/// (pushed towards white or black until they reach 4.5:1 / 3:1 contrast); Light/Dark = those four sorted by
/// luminance; Average = the mean color; Luminance = the mean relative luminance.
struct ChameleonPalette: Equatable {
    var background1: ChameleonColor
    var background2: ChameleonColor
    var foreground1: ChameleonColor
    var foreground2: ChameleonColor
    var average: ChameleonColor
    var luminance: Double

    var light: [ChameleonColor] { [background1, background2, foreground1, foreground2].sorted { $0.luminance > $1.luminance } }
    var dark: [ChameleonColor] { [background1, background2, foreground1, foreground2].sorted { $0.luminance < $1.luminance } }

    /// Chameleon's defaults when an image cannot be read (overridable with FallbackBG1 / BG2 / FG1 / FG2).
    static let fallback = ChameleonPalette(background1: ChameleonColor(r: 32, g: 32, b: 32), background2: ChameleonColor(r: 64, g: 64, b: 64),
                                           foreground1: ChameleonColor(r: 255, g: 255, b: 255),
                                           foreground2: ChameleonColor(r: 200, g: 200, b: 200),
                                           average: ChameleonColor(r: 32, g: 32, b: 32), luminance: 0.02)

    /// `Color=` of a child measure → color (nil for Luminance or unknown names).
    func color(named name: String) -> ChameleonColor? {
        switch name.muiTrimmed.lowercased() {
        case "background1", "bg1": return background1
        case "background2", "bg2": return background2
        case "foreground1", "fg1": return foreground1
        case "foreground2", "fg2": return foreground2
        case "light1": return light[0]
        case "light2": return light[1]
        case "light3": return light[2]
        case "light4": return light[3]
        case "dark1": return dark[0]
        case "dark2": return dark[1]
        case "dark3": return dark[2]
        case "dark4": return dark[3]
        case "average": return average
        default: return nil
        }
    }

    static func analyze(_ pixels: [ChameleonColor]) -> ChameleonPalette? {
        guard !pixels.isEmpty else { return nil }
        var sum = (0, 0, 0)
        var lum = 0.0
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for p in pixels {
            sum.0 += p.r
            sum.1 += p.g
            sum.2 += p.b
            lum += p.luminance
            let key = (p.r >> 4) << 8 | (p.g >> 4) << 4 | (p.b >> 4)
            var bin = bins[key] ?? (0, 0, 0, 0)
            bin.count += 1
            bin.r += p.r
            bin.g += p.g
            bin.b += p.b
            bins[key] = bin
        }
        let n = pixels.count
        let average = ChameleonColor(r: sum.0 / n, g: sum.1 / n, b: sum.2 / n)

        struct Cluster {
            var count: Int
            var r: Int
            var g: Int
            var b: Int
            var color: ChameleonColor { ChameleonColor(r: r / max(count, 1), g: g / max(count, 1), b: b / max(count, 1)) }
        }
        var clusters: [Cluster] = []
        for bin in bins.values.sorted(by: { $0.count > $1.count }) {
            let c = ChameleonColor(r: bin.r / bin.count, g: bin.g / bin.count, b: bin.b / bin.count)
            if let i = clusters.indices.min(by: { clusters[$0].color.distance(to: c) < clusters[$1].color.distance(to: c) }),
               clusters[i].color.distance(to: c) < 48 || clusters.count >= 8 {
                clusters[i].count += bin.count
                clusters[i].r += bin.r
                clusters[i].g += bin.g
                clusters[i].b += bin.b
            } else {
                clusters.append(Cluster(count: bin.count, r: bin.r, g: bin.g, b: bin.b))
            }
        }
        clusters.sort { $0.count > $1.count }
        let colors = clusters.map(\.color)
        let bg1 = colors[0]
        let bg2 = colors.dropFirst().first { $0.distance(to: bg1) >= 32 }
            ?? bg1.mixed(with: bg1.luminance > 0.4 ? .black : .white, 0.15)

        func ensureContrast(_ c: ChameleonColor, against bg: ChameleonColor, _ target: Double) -> ChameleonColor {
            if c.contrast(with: bg) >= target { return c }
            let toward = bg.luminance > 0.18 ? ChameleonColor.black : ChameleonColor.white
            var result = c
            for step in 1...10 {
                result = c.mixed(with: toward, Double(step) / 10)
                if result.contrast(with: bg) >= target { break }
            }
            return result
        }
        let candidates = colors.dropFirst().sorted { $0.contrast(with: bg1) > $1.contrast(with: bg1) }
        let fg1 = ensureContrast(candidates.first ?? bg1, against: bg1, 4.5)
        let second = candidates.dropFirst().first { $0.distance(to: fg1) >= 32 } ?? fg1.mixed(with: bg1, 0.3)
        let fg2 = ensureContrast(second, against: bg1, 3)
        return ChameleonPalette(background1: bg1, background2: bg2, foreground1: fg1, foreground2: fg2,
                                average: average, luminance: lum / Double(n))
    }

    /// Pixels of an image file, scaled down (at most 96 px on the long side), optionally cropped to `crop` (in the
    /// original image's pixels) or to the centre area with the aspect ratio `aspect` (the part of a wallpaper that
    /// "fill screen" shows).
    static func pixels(at url: URL, crop: CGRect?, aspect: CGFloat?) -> [ChameleonColor]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let fullWidth = CGFloat((props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0)
        let fullHeight = CGFloat((props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 96,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard fullWidth > 0, fullHeight > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w * h <= 1_000_000 else { return nil }
        var region = CGRect(x: 0, y: 0, width: w, height: h)
        if let crop, crop.width > 0, crop.height > 0 {
            let sx = CGFloat(w) / fullWidth, sy = CGFloat(h) / fullHeight
            region = CGRect(x: crop.minX * sx, y: crop.minY * sy, width: crop.width * sx, height: crop.height * sy)
                .intersection(region)
        } else if let aspect, aspect > 0 {
            let imageAspect = CGFloat(w) / CGFloat(h)
            if imageAspect > aspect {
                let cw = CGFloat(h) * aspect
                region = CGRect(x: (CGFloat(w) - cw) / 2, y: 0, width: cw, height: CGFloat(h))
            } else {
                let ch = CGFloat(w) / aspect
                region = CGRect(x: 0, y: (CGFloat(h) - ch) / 2, width: CGFloat(w), height: ch)
            }
        }
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var result: [ChameleonColor] = []
        let x0 = Int(region.minX), x1 = min(Int(region.maxX.rounded(.up)), w)
        // CGContext rows start at the top of the image in memory for this bitmap layout.
        let y0 = Int(region.minY), y1 = min(Int(region.maxY.rounded(.up)), h)
        result.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * w + x) * 4
                let a = Int(data[i + 3])
                guard a > 16 else { continue }
                // Un-premultiply.
                result.append(ChameleonColor(r: Int(data[i]) * 255 / a, g: Int(data[i + 1]) * 255 / a, b: Int(data[i + 2]) * 255 / a))
            }
        }
        return result
    }
}

/// `Plugin=Chameleon`: a parent (`Type=Desktop` or `Type=File` + `Path`) samples an image; children
/// (`Parent=`, `Color=`) return one of its colors. Parent string = the image path. Colors are `RRGGBB` (Format=Hex,
/// the default) or `R,G,B` (Format=Dec), without alpha, as documented.
final class ChameleonMeasure: MediaUIMeasure {
    private(set) var parentName = ""
    private var colorName = ""
    private var isDesktop = true
    private var pathOption = ""
    private(set) var hexFormat = true
    private var crop: CGRect?
    private var cropDesktop = true
    private var fallback = ChameleonPalette.fallback
    private(set) var palette: ChameleonPalette?
    private(set) var imagePath = ""
    private var paletteKey: String?
    /// Path of the check running in the background (nil = none).
    private var pendingKey: String?
    /// Path worked out by the last check (before a wallpaper folder is replaced by its image).
    private var requestedPath: String?
    private var lastCheck: TimeInterval = -1e9

    override func readMeasureOptions() {
        parentName = string("Parent").muiTrimmed
        colorName = string("Color").muiTrimmed
        isDesktop = string("Type", "Desktop").muiTrimmed.lowercased() != "file"
        pathOption = rawOption("Path") ?? ""
        hexFormat = string("Format", "Hex").muiTrimmed.lowercased() != "dec"
        let cx = optionalDouble("CropX"), cy = optionalDouble("CropY")
        let cw = optionalDouble("CropW"), ch = optionalDouble("CropH")
        if let cw, let ch, cw > 0, ch > 0 {
            crop = CGRect(x: cx ?? 0, y: cy ?? 0, width: cw, height: ch)
        } else {
            crop = nil
        }
        cropDesktop = bool("CropDesktop", true)
        var f = ChameleonPalette.fallback
        if let c = ChameleonColor(hex: string("FallbackBG1")) { f.background1 = c; f.average = c }
        if let c = ChameleonColor(hex: string("FallbackBG2")) { f.background2 = c }
        if let c = ChameleonColor(hex: string("FallbackFG1")) { f.foreground1 = c }
        if let c = ChameleonColor(hex: string("FallbackFG2")) { f.foreground2 = c }
        fallback = f
    }

    var isChild: Bool { !parentName.isEmpty }

    /// The palette children read: the sampled one, else the fallback colors.
    var effectivePalette: ChameleonPalette { palette ?? fallback }

    func format(_ c: ChameleonColor) -> String { hexFormat ? c.hex : c.decimal }

    override func computeValue() -> Double {
        if isChild {
            guard let parent = skin.measure(named: parentName) as? ChameleonMeasure, !parent.isChild else {
                logOnce("Chameleon [\(name)]: Parent=\(parentName) is not a Chameleon parent measure")
                publishString("")
                return 0
            }
            let p = parent.effectivePalette
            if colorName.lowercased() == "luminance" {
                publishString(nil)
                return p.luminance
            }
            guard let c = p.color(named: colorName) else {
                logOnce("Chameleon [\(name)]: unknown Color=\(colorName)")
                publishString("")
                return 0
            }
            publishString(parent.format(c))
            return 0
        }
        refreshImage()
        publishString(imagePath)
        return 0
    }

    /// Checks (at most every 2 s) which image to sample and starts the analysis when it changed. Only the path is
    /// worked out on the skin's thread; the file system (a wallpaper folder listing, the modification date, reading the
    /// image) is touched on a background queue — a `Path` on a network volume must not stall the skins — and the
    /// palette comes back through the skin's executor. One check at a time per measure.
    private func refreshImage() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCheck >= 2, pendingKey == nil else { return }
        lastCheck = now
        var aspect: CGFloat?
        var path = ""
        if isDesktop {
            if let desktop = ChameleonMeasure.desktop(of: controller) {
                path = desktop.picture
                if cropDesktop, crop == nil, desktop.frame.height > 0 { aspect = desktop.frame.width / desktop.frame.height }
            }
        } else {
            let resolved = skin.resolve(pathOption, in: self, sectionVariables: true).muiTrimmed
            path = resolved.isEmpty ? "" : skin.absolutePath(resolved, relativeTo: skin.directory)
        }
        // The parent's string is the configured path right away (a wallpaper folder becomes its image below).
        if path != requestedPath {
            requestedPath = path
            imagePath = path
        }
        let crop = self.crop
        let analyzed = paletteKey
        let desktop = isDesktop
        pendingKey = path
        let hop = skin.hop()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let file = desktop ? ChameleonMeasure.wallpaperFile(path) : path
            let modified = file.isEmpty ? 0 : ((try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate]
                as? Date)?.map { $0.timeIntervalSince1970 } ?? 0)
            let key = "\(file)|\(modified)|\(String(describing: crop))|\(String(describing: aspect))"
            var result: ChameleonPalette?
            let changed = key != analyzed
            if changed, !file.isEmpty, FileManager.default.fileExists(atPath: file) {
                let pixels = ChameleonPalette.pixels(at: URL(fileURLWithPath: file), crop: crop, aspect: aspect)
                result = pixels.flatMap(ChameleonPalette.analyze)
            }
            hop.post {
                guard let self else { return }
                self.pendingKey = nil
                // A check started for a path that has changed since is dropped (the next check handles the new one).
                guard self.requestedPath == path else { return }
                self.imagePath = file
                if changed {
                    self.paletteKey = key
                    self.palette = result
                }
            }
        }
    }

    /// The desktop picture setting and the frame of the screen the skin's window is on (else the main screen); nil
    /// without a screen or a desktop picture. AppKit is asked on the main thread only: a skin on another thread gets
    /// the main screen's, as the main thread last saw it (`DesktopInputs.mainScreenDesktop`). The window's own screen
    /// reaches a skin thread with the window's facts, in phase 2 (docs/skin-threading.md §8.1).
    static func desktop(of controller: SkinController?) -> DesktopInputs.ScreenDesktop? {
        guard Thread.isMainThread else { return DesktopInputs.mainScreenDesktop.value() }
        guard let screen = controller?.window.screen ?? NSScreen.main else { return nil }
        return DesktopInputs.desktop(of: screen)
    }

    /// The desktop picture of a screen: the file itself, or for a folder of rotating wallpapers its first picture by
    /// name (as the Registry `Wallpaper` value; see `DesktopPicture`). Background queue.
    static func wallpaperFile(_ path: String) -> String {
        DesktopPicture.firstPicture(inFolder: path) ?? path
    }
}

// MARK: - Inputs from AppKit

/// What SysColor and Chameleon need from AppKit, which only the main thread may ask: the app's appearance, "Reduce
/// transparency", and the main screen's desktop picture, fill color and frame. Each is worked out when the main thread
/// reads it (every skin today) and published for skins on other threads, which read the latest one and never wait
/// (`MainPublished`; docs/skin-threading.md §4.6). The app publishes them once at launch, before it loads skins, so
/// a skin on another thread has them from its first update.
enum DesktopInputs {
    /// A screen's desktop picture setting (a file, or a folder of rotating pictures) and its frame.
    struct ScreenDesktop: Equatable {
        var picture: String
        var frame: CGRect
    }

    /// The app's appearance (light or dark) that system colors resolve for.
    static let appearance = MainPublished<NSAppearance?>(maxAge: 1, initial: nil) {
        NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)
    }

    /// System Settings → Accessibility → Display → Reduce transparency.
    static let reduceTransparency = MainPublished<Bool>(maxAge: 1, initial: false) {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// The main screen's desktop fill color (the color around a picture that does not fill the screen); nil when the
    /// options do not have one.
    static let desktopFillColor = MainPublished<NSColor?>(maxAge: 2, initial: nil) {
        guard let screen = NSScreen.main else { return nil }
        return NSWorkspace.shared.desktopImageOptions(for: screen)?[.fillColor] as? NSColor
    }

    /// The main screen's desktop picture and frame.
    static let mainScreenDesktop = MainPublished<ScreenDesktop?>(maxAge: 2, initial: nil) {
        NSScreen.main.flatMap(desktop(of:))
    }

    /// Main thread.
    static func desktop(of screen: NSScreen) -> ScreenDesktop? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return ScreenDesktop(picture: url.path, frame: screen.frame)
    }

    /// Main thread: publishes every input now (at launch, before skins run elsewhere).
    static func publishAll() {
        appearance.refresh()
        reduceTransparency.refresh()
        desktopFillColor.refresh()
        mainScreenDesktop.refresh()
    }
}

// MARK: - IsFullScreen / GetActiveTitle

/// The focused app and window, refreshed off the main thread at most twice a second.
///
/// Any thread (docs/skin-threading.md §4.6): measures read the latest info under a lock. Which app is in front is
/// asked on the main thread (at once when the reader is there, else queued there), the windows on the worker. The
/// result is stored under the lock on the main thread, as before skins could leave it: between the updates of the
/// skins that run there (today every skin), so IsFullScreen and GetActiveTitle agree within one update.
final class FrontmostAppInfo {
    static let shared = FrontmostAppInfo()

    struct Info: Equatable {
        var processName = ""
        var fullScreen = false
        var title = ""
    }

    private struct State {
        var info = Info()
        var lastRefresh: TimeInterval = -1e9
        var refreshing = false
        var wantsTitle = false
    }

    let worker = MediaUIWorker(name: "Deskset focused window")
    private let state = Guarded(State())

    var info: Info { state.access { $0.info } }

    /// A GetActiveTitle measure wants the window title (reading it can take a moment, so only then).
    var wantsTitle: Bool {
        get { state.access { $0.wantsTitle } }
        set { state.access { $0.wantsTitle = newValue } }
    }

    /// Latest info; starts a refresh when the last one is older than 0.5 s.
    func current() -> Info {
        let now = ProcessInfo.processInfo.systemUptime
        let (info, start) = state.access { s -> (Info, Bool) in
            let start = !s.refreshing && now - s.lastRefresh >= 0.5
            if start {
                s.refreshing = true
                s.lastRefresh = now
            }
            return (s.info, start)
        }
        if start { MediaUIMainHop.run { self.refresh() } }
        return info
    }

    /// Main thread: which app is in front (`NSWorkspace.frontmostApplication` is not documented as safe elsewhere),
    /// then its windows on the worker.
    private func refresh() {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let name = app?.executableURL?.lastPathComponent ?? app?.localizedName ?? ""
        let appName = app?.localizedName ?? name
        let wantsTitle = self.wantsTitle
        worker.async { [weak self] in
            let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]) ?? []
            var result = Info(processName: name)
            result.fullScreen = FrontmostAppInfo.isFullScreen(windows: windows, pid: pid,
                                                              display: CGDisplayBounds(CGMainDisplayID()))
            if wantsTitle { result.title = FrontmostAppInfo.title(pid: pid, windows: windows) ?? appName }
            MediaUIMainHop.async {
                self?.state.access { s in
                    s.info = result
                    s.refreshing = false
                }
            }
        }
    }

    /// Whether the front window of `pid` (the first normal-layer window in front-to-back order) covers the primary
    /// display exactly.
    static func isFullScreen(windows: [[String: Any]], pid: pid_t, display: CGRect) -> Bool {
        guard pid > 0 else { return false }
        for w in windows {
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            return abs(bounds.minX - display.minX) < 1 && abs(bounds.minY - display.minY) < 1
                && abs(bounds.width - display.width) < 1 && abs(bounds.height - display.height) < 1
        }
        return false
    }

    /// The focused window's title: Accessibility when Deskset has that permission (never asked for here), else the
    /// window name the window server reports (only with the Screen Recording permission); nil when neither works.
    static func title(pid: pid_t, windows: [[String: Any]]) -> String? {
        guard pid > 0 else { return nil }
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                var title: CFTypeRef?
                // The type check above makes this cast safe.
                let element = window as! AXUIElement
                if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
                   let s = title as? String, !s.isEmpty {
                    return s
                }
            }
        }
        for w in windows where (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            && (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty { return name }
        }
        return nil
    }
}

/// `Plugin=IsFullScreen`: 1 when the focused app's front window fills the primary display, else 0; the string is
/// the focused app's process name (e.g. `Safari`; Windows skins compare with `chrome.exe`-style names, which never
/// match on the Mac).
final class IsFullScreenMeasure: MediaUIMeasure {
    override func computeValue() -> Double {
        let info = FrontmostAppInfo.shared.current()
        publishString(info.processName)
        return info.fullScreen ? 1 : 0
    }
}

/// `Plugin=GetActiveTitle`: the focused window's title (the app's name when the title cannot be read); the number
/// is the title's length (version 1.3 of the plugin).
final class ActiveTitleMeasure: MediaUIMeasure {
    override func computeValue() -> Double {
        FrontmostAppInfo.shared.wantsTitle = true
        let title = FrontmostAppInfo.shared.current().title
        publishString(title)
        return Double(title.count)
    }
}

// MARK: - SysColor

enum SysColorFormat {
    enum Display: String {
        case all, rgb, red, green, blue, alpha
    }

    /// DisplayType + Hex (SysColor README): ALL `r,g,b,a` / `RRGGBBAA`, RGB `r,g,b` / `RRGGBB`, one channel `n` / `NN`.
    static func format(_ c: RGBA, display: Display, hex: Bool) -> String {
        func channel(_ v: Double) -> Int { Int(min(max(v, 0), 255).rounded()) }
        let values: [Int]
        switch display {
        case .all: values = [channel(c.r), channel(c.g), channel(c.b), channel(c.a)]
        case .rgb: values = [channel(c.r), channel(c.g), channel(c.b)]
        case .red: values = [channel(c.r)]
        case .green: values = [channel(c.g)]
        case .blue: values = [channel(c.b)]
        case .alpha: values = [channel(c.a)]
        }
        return hex ? values.map { String(format: "%02X", $0) }.joined() : values.map(String.init).joined(separator: ",")
    }

    /// Windows system color names → macOS semantic colors (Judgment; see docs/compat/media-ui.md). nil = unknown.
    static func color(_ type: String) -> NSColor? {
        switch type.muiTrimmed.lowercased() {
        case "", "accent", "aero", "win8", "dwm_color", "dwm_afterglow", "menuhighlight":
            return NSColor.controlAccentColor
        case "highlight": return NSColor.selectedContentBackgroundColor
        case "desktop":
            return DesktopInputs.desktopFillColor.value() ?? NSColor.windowBackgroundColor
        case "window", "menu", "menubar", "activecaption", "activecaptiongradient", "inactivecaption",
             "inactivecaptiongradient", "tooltipbackground":
            return NSColor.windowBackgroundColor
        case "buttonface": return NSColor.controlColor
        case "windowtext", "menutext", "captiontext", "buttontext", "tooltiptext": return NSColor.labelColor
        case "inactivecaptiontext", "graytext": return NSColor.disabledControlTextColor
        case "windowframe", "activeborder", "inactiveborder": return NSColor.separatorColor
        case "hightlighttext", "highlighttext": return NSColor.selectedMenuItemTextColor
        case "buttonhighlight", "3dlight": return NSColor.highlightColor
        case "buttonshadow", "3ddarkshadow": return NSColor.shadowColor
        case "appworkspace": return NSColor.underPageBackgroundColor
        case "scrollbar": return NSColor.controlBackgroundColor
        case "hyperlink": return NSColor.linkColor
        default: return nil
        }
    }

    /// The color in sRGB, resolved for the app's light / dark appearance (published by the main thread; resolving a
    /// color for an appearance works on any thread: the drawing appearance is the thread's own).
    static func resolved(_ color: NSColor) -> RGBA? {
        var result: RGBA?
        let appearance = DesktopInputs.appearance.value() ?? NSAppearance(named: .aqua)
        let resolve = {
            if let c = color.usingColorSpace(.sRGB) {
                result = RGBA(r: Double(c.redComponent) * 255, g: Double(c.greenComponent) * 255,
                              b: Double(c.blueComponent) * 255, a: Double(c.alphaComponent) * 255)
            }
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(resolve) } else { resolve() }
        return result
    }
}

/// `Plugin=SysColor`: `ColorType` (default Accent), `DisplayType` (default All), `Hex` (default 0). Number: 1 when
/// the color was found, -1 when not. DWM_* balance / intensity values have no Mac equivalent: DWM_OPAQUE_BLEND is 1
/// when "Reduce transparency" is on, the others 0.
final class SysColorMeasure: MediaUIMeasure {
    private var colorType = "Accent"
    private var display = SysColorFormat.Display.all
    private var hex = false

    override func readMeasureOptions() {
        colorType = string("ColorType", "Accent").muiTrimmed
        display = SysColorFormat.Display(rawValue: string("DisplayType", "All").muiTrimmed.lowercased()) ?? .all
        hex = bool("Hex", false)
    }

    override func computeValue() -> Double {
        switch colorType.lowercased() {
        case "dwm_opaque_blend":
            publishString(DesktopInputs.reduceTransparency.value() ? "1" : "0")
            return 1
        case "dwm_color_balance", "dwm_afterglow_balance", "dwm_blur_balance", "dwm_glass_reflection_intensity":
            publishString("0")
            return 1
        default:
            break
        }
        guard let color = SysColorFormat.color(colorType), let rgba = SysColorFormat.resolved(color) else {
            logOnce("SysColor [\(name)]: ColorType=\(colorType) is not available")
            publishString("")
            return -1
        }
        publishString(SysColorFormat.format(rgba, display: display, hex: hex))
        return 1
    }
}
