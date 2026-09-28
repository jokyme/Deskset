#if DEBUG
import AppKit
import DesksetCore

/// The frozen copy of the renderer (`LegacyRender/`, debug builds only) draws what the renderer draws, byte for byte:
/// the same skins, in one process, at the same moment, through both paths — `--render`'s bitmap in sRGB at 1x and 2x,
/// and at 2x also in the device RGB space and a skin window's full picture — light and dark. It is the reference the
/// renderer is compared with while its code moves, so these checks have to hold before anything moves.
enum LegacyRenderSelfTests {
    /// The TestSkins folders drawn: every meter type, containers, glass, SF Symbols, the system font designs, inline
    /// text options, and the example skins.
    static let folders = ["Graphs", "Image", "Round", "Shape", "String", "Mac", "Engine/Container", "Engine/Layout",
                          "Engine/Compat", "Deskset"]
    /// Left to the command-line comparison: String/Review draws a very long text with combining marks, seconds per
    /// picture in a debug build.
    static let skipped = ["String/Review/Review.ini"]
    /// `DESKSET_LEGACY_RENDER_EXTRA`: more skins to draw both ways, as `.ini` files or folders of them separated by
    /// colons (a local corpus, or skins whose data changes from run to run, which only a comparison in one process at
    /// one moment can check). They are drawn where they are, so pass copies: skins may write their own files.
    static var extraSkins: [URL] {
        let list = ProcessInfo.processInfo.environment["DESKSET_LEGACY_RENDER_EXTRA"] ?? ""
        return list.split(separator: ":").flatMap { item -> [URL] in
            let url = URL(fileURLWithPath: String(item)).standardizedFileURL
            return url.pathExtension.lowercased() == "ini" ? [url] : iniFiles(in: url)
        }
    }

    static func run(_ t: AppTestRunner) {
        t.suite("Runtime: legacy renderer: draws the TestSkins byte for byte as the renderer does") {
            guard let testSkins = Paths.repositoryFolder("TestSkins") else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            // A copy: skins may write their own files.
            let skins = t.temporaryDirectory("legacy-render").appendingPathComponent("TestSkins")
            try FileManager.default.copyItem(at: testSkins, to: skins)
            let set = folders.flatMap { iniFiles(in: skins.appendingPathComponent($0)) }
                .filter { file in !skipped.contains { file.path.hasSuffix("/" + $0) } }
            t.check(set.count >= 30, "the TestSkins set is there: \(set.count) skins")
            let files = set + extraSkins
            let savedAppearance = NSApp.appearance
            defer {
                NSApp.appearance = savedAppearance
                MacAppearance.current.refresh()
                DesktopInputs.appearance.refresh()
            }
            var drawn = 0, withPixels = 0
            for appearance in [RenderOptions.Appearance.light, .dark] {
                RenderCommand.applyAppearance(appearance)
                for file in files {
                    let name = file.path.replacingOccurrences(of: skins.path + "/", with: "")
                        + " (\(appearance.rawValue))"
                    let inSet = file.path.hasPrefix(skins.path + "/")
                    let (root, config) = RenderCommand.locate(file, skinsDir: inSet ? skins.path : nil)
                    let host = RenderHost()
                    let skin = Skin(config: config, fileURL: file, skinsDirectory: root, system: SystemMonitor.shared,
                                    host: host)
                    // The skin holds its host weakly.
                    withExtendedLifetime(host) {
                        guard (try? skin.load()) != nil else {
                            t.check(false, "\(name) loads")
                            return
                        }
                        Fonts.registerFonts(for: skin)
                        skin.update()
                        skin.update()
                        let result = compare(skin, name, t)
                        drawn += result.drawn
                        if result.hasPixels { withPixels += 1 }
                        skin.close()
                    }
                }
            }
            t.check(drawn >= files.count * 2 * 4, "every skin drawn both ways at 1x and 2x: \(drawn) pictures")
            // Not an empty comparison: nearly every skin draws something.
            t.check(withPixels >= set.count * 2 - 4, "\(withPixels) of \(files.count * 2) drawings have pixels")
        }

        t.suite("Runtime: legacy renderer: a difference is found") {
            guard let loaded = SkinDrawingSelfTests.load(t, """
                [Rainmeter]
                Update=-1
                [Square]
                Meter=Image
                W=20
                H=20
                SolidColor=200,40,40,255
                """, "legacy-canary") else {
                t.check(false, "the canary skin loads")
                return
            }
            let skin = loaded.skin
            defer { withExtendedLifetime(loaded.host) { skin.close() } }
            guard let before = pngs(skin, scale: 1, colorSpace: .srgb) else {
                t.check(false, "the canary is drawn")
                return
            }
            t.check(before.current == before.legacy, "the same skin draws the same both ways")
            // One of the two paths drawing another picture must show.
            skin.execute("[!SetOption Square SolidColor 200,40,41,255][!UpdateMeter Square]", from: nil)
            guard let after = pngs(skin, scale: 1, colorSpace: .srgb) else {
                t.check(false, "the changed canary is drawn")
                return
            }
            t.check(after.current != before.legacy, "one level of one channel differs")
            t.check(pixelsEqual(after.current, before.legacy) == false, "and the pixel comparison finds it")
        }

        t.suite("Runtime: legacy renderer: --render --legacy gives the same bytes as --render") {
            guard let testSkins = Paths.repositoryFolder("TestSkins") else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            typealias V = CommandLineTools.Validation
            let program = ["/Applications/Deskset.app/Contents/MacOS/Deskset"]
            t.equal(CommandLineTools.validate(program + ["--render", "a.ini", "--legacy"]), V.mode)
            t.equal(CommandLineTools.validate(program + ["--legacy"]),
                    V.invalid("--legacy needs one of --render, --snapshot-ui, --weather-report"))
            t.check(RenderOptions.parse(["Deskset", "--render", "a.ini", "--legacy"])?.legacy == true)
            t.check(RenderOptions.parse(["Deskset", "--render", "a.ini"])?.legacy == false)
            t.check(!CommandLineTools.usage.contains("--legacy"), "a development flag, not in the usage")

            let root = t.temporaryDirectory("legacy-render-command")
            let skins = root.appendingPathComponent("TestSkins")
            try FileManager.default.copyItem(at: testSkins, to: skins)
            let data = skins.appendingPathComponent("Runtime/Data/mac.json").path
            let out = root.appendingPathComponent("out")
            for skin in ["Deskset/System/System.ini", "String/Inline/Inline.ini", "Mac/Glass/Glass.ini",
                         "Shape/Paint/Paint.ini"] {
                var images: [Data?] = []
                for legacy in [false, true] {
                    let png = out.appendingPathComponent(skin.replacingOccurrences(of: "/", with: "_")
                                                         + (legacy ? ".legacy.png" : ".png"))
                    let status = RenderCommand.run(["Deskset", "--render", skins.appendingPathComponent(skin).path,
                                                    "--out", png.path, "--updates", "3", "--scale", "2",
                                                    "--clock", "2026-09-26T12:00:00Z", "--time-zone", "Europe/Oslo",
                                                    "--seed", "7", "--data", data, "--color-space", "srgb"]
                                                   + (legacy ? ["--legacy"] : []))
                    t.equal(status, 0, "\(skin) renders")
                    images.append(try? Data(contentsOf: png))
                }
                t.check(images[0] != nil && images[0] == images[1], "\(skin): the same bytes")
            }
        }
    }

    /// Draws `skin` both ways and checks the bytes: `--render`'s bitmap in sRGB (the reference images' space) at 1x
    /// and 2x, and at 2x also in device RGB (`--render`'s default) and the skin window's full picture. Returns the
    /// number of pictures compared, and whether it drew anything at all.
    static func compare(_ skin: Skin, _ name: String, _ t: AppTestRunner) -> (drawn: Int, hasPixels: Bool) {
        var drawn = 0, hasPixels = false
        for scale in [1.0, 2.0] {
            for space in scale == 2 ? [RenderOptions.ColorSpace.srgb, .device] : [.srgb] {
                guard let pair = pngs(skin, scale: scale, colorSpace: space) else {
                    t.check(false, "\(name) is drawn at \(scale)x (\(space.rawValue))")
                    continue
                }
                t.check(pair.current == pair.legacy, "\(name) at \(Int(scale))x (\(space.rawValue)): the same bytes")
                drawn += 1
            }
            // The skin window's picture: glass as its hit areas, in the window's 8-bit BGRA bitmap.
            guard scale == 2 else { continue }
            let w = max(Int((skin.width * scale).rounded(.up)), 1), h = max(Int((skin.height * scale).rounded(.up)), 1)
            guard w <= 8192, h <= 8192, let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let current = SkinBitmapDrawing.fullDrawing(of: skin, w, h, scale: CGFloat(scale), space: space),
                  let legacy = LegacySkinBitmapDrawing.fullDrawing(of: skin, w, h, scale: CGFloat(scale), space: space),
                  let a = current.makeImage(), let b = legacy.makeImage() else {
                t.check(false, "\(name): the window's picture is drawn at \(scale)x")
                continue
            }
            t.check(bytesEqual(a, b), "\(name) at \(Int(scale))x (window): the same bytes")
            if !hasPixels { hasPixels = !isEmpty(a) }
            drawn += 1
        }
        return (drawn, hasPixels)
    }

    /// `--render`'s PNG of `skin` as it stands, through the renderer and through the frozen copy.
    static func pngs(_ skin: Skin, scale: Double, colorSpace: RenderOptions.ColorSpace)
        -> (current: Data, legacy: Data)? {
        let w = min(max(Int(ceil(max(skin.width, 1) * scale)), 1), RenderOptions.maxPixels)
        let h = min(max(Int(ceil(max(skin.height, 1) * scale)), 1), RenderOptions.maxPixels)
        var options = RenderOptions(input: "")
        options.colorSpace = colorSpace
        guard let current = RenderCommand.draw(skin, width: w, height: h, scale: scale, options: options) else {
            return nil
        }
        options.legacy = true
        guard let legacy = RenderCommand.draw(skin, width: w, height: h, scale: scale, options: options) else {
            return nil
        }
        return (current, legacy)
    }

    /// The `.ini` files under `folder` (not in @Resources), sorted.
    static func iniFiles(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "ini" && !$0.path.contains("/@Resources/") }
            .sorted { $0.path < $1.path }
    }

    /// Whether two images have the same size, pixel format and bytes, pixel for pixel.
    static func bytesEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, a.bitsPerPixel == b.bitsPerPixel,
              a.bitmapInfo == b.bitmapInfo, let pa = rows(a), let pb = rows(b) else { return false }
        return pa == pb
    }

    /// Whether two PNGs hold the same pixels (nil when one cannot be read).
    static func pixelsEqual(_ a: Data, _ b: Data) -> Bool? {
        guard let ra = NSBitmapImageRep(data: a)?.cgImage, let rb = NSBitmapImageRep(data: b)?.cgImage else { return nil }
        return bytesEqual(ra, rb)
    }

    /// Whether every byte of the image is 0 (transparent black in the premultiplied formats drawn here).
    static func isEmpty(_ image: CGImage) -> Bool {
        guard let bytes = rows(image) else { return true }
        return !bytes.contains { $0 != 0 }
    }

    /// The image's rows as stored, without the padding at their ends: two images of one pixel format are the same
    /// pixels exactly when these are equal (copied, never drawn, so no color matching or rounding).
    static func rows(_ image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let row = image.width * image.bitsPerPixel / 8
        var out: [UInt8] = []
        out.reserveCapacity(row * image.height)
        for y in 0..<image.height {
            let start = y * image.bytesPerRow
            guard start + row <= data.count else { return nil }
            out.append(contentsOf: data[start..<start + row])
        }
        return out
    }
}
#endif
