import AppKit
import DesksetCore

/// Checks that a skin window's picture (`SkinBitmapDrawing`, which copies the meters that did not change) always shows
/// what a full drawing of the skin shows:
///
///     Deskset --verify-drawing-cache SkinsFolder|Skin.ini… [--updates N] [--scale S] [--skins-dir DIR]
///
/// Each skin is loaded without a window from a temporary copy of its Skins folder (so nothing it writes, and none of the
/// image files the check changes, touch the original) and goes through updates, redraws without an update, the mouse
/// over and off the meters that react to it, clicks, meter groups shown and hidden, an option set and redrawn before the
/// meter updates, image files replaced on disk, and another backing scale. After every step its picture is compared,
/// pixel for pixel, with a full drawing (`SkinBitmapDrawing.tolerance` levels per channel allowed for rounding).
///
/// The skins run like the Studio's own instance of a widget (`StudioActionPolicy`): they change nothing outside
/// themselves — no web pages or programs opened, no files written, no players or other widgets told anything — and, as
/// with `--render`, they never ask for a permission (no Apple Events, no location, no audio capture).
enum DrawingCacheCheck {
    struct Options: Equatable {
        var paths: [String] = []
        var updates = 5
        var scale: CGFloat = 2
        var skinsDirectory: String?
    }

    /// What happened to one skin.
    struct SkinResult {
        var config: String
        var file: String
        var frames = 0
        /// Frames that copied at least one kept picture.
        var copiedFrames = 0
        /// The largest difference of one channel seen in any frame.
        var worst = 0
        /// Frames whose picture differed from a full drawing by more than the tolerance: step, worst, pixels.
        var mismatches: [String] = []
        /// Why the skin was not checked (it does not load, or it is too large).
        var skipped: String?
        /// Image files the check replaced while the skin ran.
        var imagesReplaced = 0
        /// How long the check of the skin took.
        var seconds = 0.0
    }

    /// Everything checked.
    struct Summary {
        var results: [SkinResult] = []
        var checked: Int { results.filter { $0.skipped == nil }.count }
        var skipped: Int { results.filter { $0.skipped != nil }.count }
        var mismatched: [SkinResult] { results.filter { !$0.mismatches.isEmpty } }
        var frames: Int { results.reduce(0) { $0 + $1.frames } }
        var copiedFrames: Int { results.reduce(0) { $0 + $1.copiedFrames } }
    }

    static let usage = "usage: Deskset --verify-drawing-cache SkinsFolder|Skin.ini… [--updates N] [--scale S] "
        + "[--skins-dir DIR]"

    /// Largest picture checked, in pixels (larger skins are skipped).
    static let maxPixels = 4096 * 4096
    /// Pause between updates, so timers and asynchronous results (!Delay, transitions, plugins) come in between.
    static let updateInterval = 25.0

    static func parse(_ arguments: [String]) -> Options? {
        guard let start = arguments.firstIndex(of: "--verify-drawing-cache") else { return nil }
        var o = Options()
        var i = start + 1
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "--updates", "--scale", "--skins-dir":
                let v = i + 1 < arguments.count ? arguments[i + 1] : ""
                if a == "--updates", let n = Int(v) { o.updates = min(max(n, 1), 1000) }
                if a == "--scale", let s = Double(v), s.isFinite { o.scale = CGFloat(min(max(s, 0.5), 4)) }
                if a == "--skins-dir" { o.skinsDirectory = v }
                i += 2
            default:
                if !a.hasPrefix("--") { o.paths.append(a) }
                i += 1
            }
        }
        return o.paths.isEmpty ? nil : o
    }

    static func run(_ arguments: [String]) -> Int32 {
        guard let o = parse(arguments) else {
            fputs(usage + "\n", stderr)
            return 2
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesksetDrawingCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var summary = Summary()
        withCheckEnvironment(temporary) {
            for (index, path) in o.paths.enumerated() {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                    fputs("error: no such file or folder: \(url.path)\n", stderr)
                    continue
                }
                let root: URL
                var only: String?
                if isFolder.boolValue {
                    root = url
                } else {
                    root = RenderCommand.locate(url, skinsDir: o.skinsDirectory).0
                    only = String(url.path.dropFirst(root.path.count))
                }
                let copy = temporary.appendingPathComponent("Skins\(index)", isDirectory: true)
                do {
                    try FileManager.default.copyItem(at: root, to: copy)
                } catch {
                    fputs("error: cannot copy \(root.path): \(error.localizedDescription)\n", stderr)
                    continue
                }
                let files = only.map { [copy.appendingPathComponent($0)] } ?? skinFiles(in: copy)
                for file in files {
                    let result = check(file, skinsRoot: copy, updates: o.updates, scale: o.scale)
                    print(line(for: result))
                    summary.results.append(result)
                }
            }
        }
        print("")
        print("\(summary.checked) skins checked (\(summary.skipped) skipped), \(summary.frames) frames, "
              + "\(summary.copiedFrames) with kept pictures; \(summary.mismatched.count) skins differed from a full drawing")
        return summary.mismatched.isEmpty ? 0 : 1
    }

    static func line(for r: SkinResult) -> String {
        if let skipped = r.skipped { return "skip      \(r.config) \(r.file): \(skipped)" }
        if r.mismatches.isEmpty {
            return "ok        \(r.config) \(r.file): \(r.frames) frames, \(r.copiedFrames) with kept pictures, worst \(r.worst)"
                + (r.imagesReplaced > 0 ? ", \(r.imagesReplaced) image files replaced" : "")
                + (r.seconds >= 2 ? String(format: " (%.1f s)", r.seconds) : "")
        }
        return "MISMATCH  \(r.config) \(r.file): " + r.mismatches.prefix(4).joined(separator: "; ")
            + (r.mismatches.count > 4 ? "; … \(r.mismatches.count) frames" : "")
    }

    /// Runs `body` with what the check needs set up for its duration: a temporary `#SETTINGSPATH#`, the Light
    /// appearance and standard regional settings (as `--render` has them), the weather from the bundled places only.
    static func withCheckEnvironment(_ temporary: URL, _ body: () -> Void) {
        let settings = temporary.appendingPathComponent("Settings", isDirectory: true)
        try? FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: settings.appendingPathComponent(DefaultSkins.stationeryFileName).path,
                                       contents: Data(DefaultSkins.stationeryFileHeader.utf8))
        let savedSettings = SkinController.settingsPath
        SkinController.settingsPath = settings.path + "/"
        MacRegional.fix(MacRegionalSettings.standard)
        RenderCommand.applyAppearance(.light)
        WeatherWiring.installPreview()
        defer {
            SkinController.settingsPath = savedSettings
            MacRegional.fix(nil)
            MacAppearance.current.refresh()
        }
        body()
    }

    /// Every skin file in a Skins folder: `Root/Config…/Skin.ini`, not in `@Resources` (included files, not skins).
    static func skinFiles(in root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        let rootCount = root.standardizedFileURL.pathComponents.count
        for case let url as URL in walker where url.pathExtension.lowercased() == "ini" {
            let components = url.standardizedFileURL.pathComponents
            guard components.count >= rootCount + 3,
                  !components.contains(where: { $0.caseInsensitiveCompare("@Resources") == .orderedSame }) else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: One skin

    /// Loads `file` from `skinsRoot` (a copy the check may change), runs it through the steps and compares every frame.
    static func check(_ file: URL, skinsRoot: URL, updates: Int, scale: CGFloat,
                      space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> SkinResult {
        let parent = file.deletingLastPathComponent().standardizedFileURL.pathComponents
        let config = parent.dropFirst(skinsRoot.standardizedFileURL.pathComponents.count).joined(separator: "\\")
        var result = SkinResult(config: config, file: file.lastPathComponent)
        let started = ProcessInfo.processInfo.systemUptime
        let host = RenderHost()
        let skin = Skin(config: config, fileURL: file, skinsDirectory: skinsRoot, system: SystemMonitor.shared, host: host)
        let policy = StudioActionPolicy()
        skin.actionPolicy = policy
        do {
            try skin.load()
        } catch {
            result.skipped = "does not load (\(error))"
            return result
        }
        defer { skin.close() }
        Fonts.registerFonts(for: skin)
        let drawing = SkinBitmapDrawing()
        var frameScale = scale

        /// One frame after `action` (and an update when `update`), compared with a full drawing.
        func frame(_ label: String, _ action: String? = nil, update: Bool = false) {
            guard result.skipped == nil else { return }
            if let action { skin.execute(action, from: nil) }
            if update { skin.update() }
            let size = CGSize(width: side(skin.width), height: side(skin.height))
            let w = Int((size.width * frameScale).rounded(.up)), h = Int((size.height * frameScale).rounded(.up))
            guard w * h <= maxPixels else {
                result.skipped = "too large (\(w)×\(h) pixels)"
                return
            }
            guard let picture = drawing.picture(of: skin, size: size, scale: frameScale, space: space,
                                                appearance: "check"),
                  let full = SkinBitmapDrawing.fullDrawing(of: skin, w, h, scale: frameScale, space: space),
                  let found = SkinBitmapDrawing.difference(picture, full) else { return }
            result.frames += 1
            if drawing.lastStats.copied > 0 { result.copiedFrames += 1 }
            result.worst = max(result.worst, found.worst)
            if found.worst > SkinBitmapDrawing.tolerance {
                result.mismatches.append("\(label): \(found.worst) at \(found.x),\(found.y), \(found.pixels) pixels")
            }
        }
        func wait() { RenderCommand.wait(milliseconds: updateInterval) }
        /// Two frames without a change, so the next step starts from pictures kept of everything that rests (the case
        /// a stale picture shows in).
        func rest(_ label: String) {
            frame("\(label), resting", "[!Redraw]")
            frame("\(label), rested")
        }

        // Updates, then frames without one (everything kept).
        for i in 0..<updates {
            if i > 0 { wait() }
            frame("update \(i + 1)", update: true)
        }
        frame("redraw", "[!Redraw]")
        frame("again")

        // The mouse over each meter that reacts to it, then off the skin.
        let visible = skin.meters.filter { !$0.hidden && $0.frame.width > 0 && $0.frame.height > 0 }
        let hovered = visible.filter {
            $0.mouseActions[.over] != nil || $0.mouseActions[.leave] != nil || $0.handlesMouseItself
        }
        for m in hovered.prefix(12) {
            skin.mouseMoved(x: m.frame.x + m.frame.width / 2, y: m.frame.y + m.frame.height / 2)
            frame("over [\(m.name)]")
        }
        if !hovered.isEmpty {
            skin.mouseExited()
            frame("mouse left")
            wait()
            frame("update after the mouse", update: true)
        }

        // Clicks (what would reach outside the skin is recorded by the policy, not done).
        let clicked = visible.filter { $0.mouseActions[.leftUp] != nil || $0.mouseActions[.leftDown] != nil
            || $0 is ButtonMeter }
        for m in clicked.prefix(6) {
            let x = m.frame.x + m.frame.width / 2, y = m.frame.y + m.frame.height / 2
            skin.mouseMoved(x: x, y: y)
            skin.mouseEvent(.leftDown, x: x, y: y)
            frame("pressed [\(m.name)]")
            skin.mouseEvent(.leftUp, x: x, y: y)
            frame("clicked [\(m.name)]")
            wait()
            frame("update after clicking [\(m.name)]", update: true)
        }
        if !clicked.isEmpty {
            skin.mouseExited()
            frame("mouse left again")
        }

        // Meter groups hidden and shown again, redrawn without an update.
        rest("before the groups")
        var groups: [String] = []
        for m in skin.meters { for g in m.groups where !groups.contains(g) { groups.append(g) } }
        for g in groups.prefix(3) {
            frame("group \(g) toggled", "[!ToggleMeterGroup \"\(g)\"][!Redraw]")
            frame("group \(g) back", "[!ToggleMeterGroup \"\(g)\"][!Redraw]")
        }

        // An option set and redrawn before the meter updates, then updated.
        if let m = visible.first(where: { $0 is StringMeter }) ?? visible.first {
            rest("before an option")
            frame("option set, redrawn", "[!SetOption \"\(m.name)\" SolidColor 255,0,0,120][!Redraw]")
            frame("option set, meter updated", "[!UpdateMeter \"\(m.name)\"][!Redraw]")
            frame("option cleared", "[!SetOption \"\(m.name)\" SolidColor \"\"][!UpdateMeter \"\(m.name)\"][!Redraw]")
        }

        // Image files replaced on disk (in the copy), redrawn without an update.
        rest("before the image files")
        let replaced = imageFiles(of: skin, under: skinsRoot).prefix(3).filter(replaceImage)
        result.imagesReplaced = replaced.count
        if !replaced.isEmpty {
            frame("\(replaced.count) image files replaced", "[!Redraw]")
            frame("image files replaced, kept")
            wait()
            frame("update after the image files", update: true)
        }

        // Another backing scale, and back.
        frameScale = scale == 1 ? 2 : 1
        frame("\(frameScale)x")
        frameScale = scale
        frame("\(scale)x again")
        for i in 0..<2 {
            wait()
            frame("last update \(i + 1)", update: true)
        }
        result.seconds = ProcessInfo.processInfo.systemUptime - started
        return withExtendedLifetime((host, policy)) { result }
    }

    /// A window side as the skin window has it (`SkinController.skinSize`).
    private static func side(_ v: Double) -> CGFloat {
        guard v.isFinite else { return 1 }
        return min(max(CGFloat(v), 1), SkinController.maxWindowSide)
    }

    /// The image files (PNG and JPEG) the skin's meters and background show, inside `root`.
    static func imageFiles(of skin: Skin, under root: URL) -> [String] {
        var paths: [String] = []
        func add(_ path: String?) {
            guard let path, !MacSymbol.isSymbolPath(path), path.hasPrefix(root.path), !paths.contains(path),
                  ["png", "jpg", "jpeg"].contains((path as NSString).pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: path) else { return }
            paths.append(path)
        }
        add(skin.settings.backgroundImage)
        for m in skin.meters where !m.hidden {
            switch m {
            case let m as ImageMeter: add(m.imagePath)
            case let m as BarMeter: add(m.barImagePath)
            case let m as ButtonMeter: add(m.buttonImagePath)
            case let m as BitmapMeter: add(m.bitmapImagePath)
            case let m as RotatorMeter: add(m.imagePath)
            default: break
            }
        }
        return paths
    }

    /// Replaces an image file with the same picture in inverted colors (same size and type); false when it cannot be
    /// read or written.
    static func replaceImage(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: rect)
        ctx.setBlendMode(.difference)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        // Keep the alpha of the original: the inverted colors only where it was drawn.
        ctx.setBlendMode(.destinationIn)
        ctx.draw(image, in: rect)
        guard let inverted = ctx.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, inverted, nil)
        return CGImageDestinationFinalize(destination)
    }
}
