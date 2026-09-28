import AppKit
import ImageIO
import UniformTypeIdentifiers
import DesksetCore

/// `Deskset --self-test Chameleon desktop`: Chameleon's `CropDesktop=Skin` (the part of the wallpaper under the skin
/// window), dynamic desktop pictures and the folders it never reads. Stand-in desktops only: nothing here reads the
/// Mac's wallpaper, shows a window or touches a folder macOS guards.
enum ChameleonDesktopSelfTests {
    static func run(_ t: AppTestRunner) {
        optionTests(t)
        placementTests(t)
        protectedTests(t)
        dynamicTests(t)
        samplerTests(t)
        measureTests(t)
        renderTests(t)
    }

    // MARK: Helpers

    /// A PNG of `width` × `height` pixels: its left half `left`, its right half `right` (gray levels 0…1).
    static func halves(_ url: URL, width: Int = 200, height: Int = 100, left: CGFloat = 0, right: CGFloat = 1,
                       dpi: CGFloat = 72) throws {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(srgbRed: left, green: left, blue: left, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(srgbRed: right, green: right, blue: right, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// A two-picture TIFF with Apple's dynamic desktop metadata: picture 0 is light gray, picture 1 dark gray, and the
    /// metadata names `light` and `dark` (under `key`, inside `ap` when `nested`).
    static func dynamicPicture(_ url: URL, light: Int, dark: Int, key: String = "apr", nested: Bool = false) {
        func gray(_ g: CGFloat) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(srgbRed: g, green: g, blue: g, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            return ctx.makeImage()
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil),
              let a = gray(0.9), let b = gray(0.1) else { return }
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.apple.com/namespace/1.0/" as CFString,
                                                  "apple_desktop" as CFString, nil)
        let entries: [String: Any] = nested ? ["ap": ["l": light, "d": dark], "ti": [["i": 0, "t": 0.5]]]
                                            : ["l": light, "d": dark]
        if let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0) {
            CGImageMetadataSetValueWithPath(metadata, nil, "apple_desktop:\(key)" as CFString,
                                            data.base64EncodedString() as CFString)
        }
        CGImageDestinationAddImageAndMetadata(dest, a, metadata, nil)
        CGImageDestinationAddImage(dest, b, nil)
        CGImageDestinationFinalize(dest)
    }

    static func base64Plist(_ value: Any) -> String {
        (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))?
            .base64EncodedString() ?? ""
    }

    /// Runs `body` with `desktops` standing in for the Mac's.
    static func withDesktops(_ desktops: [ScreenDesktop], _ body: () throws -> Void) rethrows {
        let saved = DesktopInputs.fake.current
        DesktopInputs.fake.access { $0 = desktops }
        defer { DesktopInputs.fake.access { $0 = saved } }
        try body()
    }

    // MARK: CropDesktop

    static func optionTests(_ t: AppTestRunner) {
        t.suite("App: Chameleon desktop: CropDesktop=Skin is a mode, not a yes") {
            typealias Crop = ChameleonMeasure.CropDesktop
            t.equal(Crop.parse("Skin"), .skin)
            t.equal(Crop.parse(" skin "), .skin)
            t.equal(Crop.parse("SKIN"), .skin)
            t.equal(Crop.parse(""), .screen, "the default")
            t.equal(Crop.parse("1"), .screen)
            t.equal(Crop.parse("0"), .off)
            t.equal(Crop.parse("(1 - 1)"), .off, "a formula")
            t.equal(Crop.parse("Skins"), .screen, "any other word reads as the default, as before")

            let (skin, _) = try MediaUITests.bareSkin(t)
            func parent(_ options: [(String, String)]) -> ChameleonMeasure {
                let m = ChameleonMeasure(name: "Wall", section: MediaUITests.section("Wall", options), skin: skin,
                                         type: "chameleon")
                m.readOptions()
                return m
            }
            t.check(parent([("Type", "Desktop"), ("CropDesktop", "Skin")]).samplesUnderSkin)
            t.check(!parent([("CropDesktop", "Skin")]).isChild)
            t.check(parent([("CropDesktop", "Skin")]).samplesUnderSkin, "Type=Desktop is the default")
            t.check(!parent([("Type", "File"), ("Path", "a.png"), ("CropDesktop", "Skin")]).samplesUnderSkin,
                    "a file has no skin to crop to")
            t.check(!parent([("CropDesktop", "Skin"), ("CropW", "10"), ("CropH", "10")]).samplesUnderSkin,
                    "CropX/Y/W/H win")
            t.check(!parent([("CropDesktop", "1")]).samplesUnderSkin)
            t.equal(parent([("CropDesktop", "Skin")]).cropDesktop, .skin)
        }
    }

    // MARK: Placement

    static func placementTests(_ t: AppTestRunner) {
        t.suite("App: Chameleon desktop: how macOS lays the picture on the screen") {
            typealias P = DesktopPlacement
            t.equal(P(options: nil), .fill, "no options: Fill Screen")
            t.equal(P(options: [:]), .fill)
            let scaling = NSWorkspace.DesktopImageOptionKey.imageScaling
            let clipping = NSWorkspace.DesktopImageOptionKey.allowClipping
            t.equal(P(options: [scaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                                clipping: NSNumber(value: true)]), .fill)
            t.equal(P(options: [scaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                                clipping: NSNumber(value: false)]), .fit)
            t.equal(P(options: [scaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue)]), .stretch)
            t.equal(P(options: [scaling: NSNumber(value: NSImageScaling.scaleNone.rawValue)]), .center)
            t.equal(P(options: [scaling: NSNumber(value: NSImageScaling.scaleProportionallyDown.rawValue)]), .shrink)

            let picture = CGSize(width: 200, height: 100), screen = CGSize(width: 100, height: 100)
            t.equal(P.fill.pictureRect(picture: picture, screen: screen), CGRect(x: -50, y: 0, width: 200, height: 100),
                    "fill: the sides are cut")
            t.equal(P.fit.pictureRect(picture: picture, screen: screen), CGRect(x: 0, y: 25, width: 100, height: 50),
                    "fit: bands above and below")
            t.equal(P.stretch.pictureRect(picture: picture, screen: screen), CGRect(x: 0, y: 0, width: 100, height: 100))
            t.equal(P.center.pictureRect(picture: picture, screen: CGSize(width: 400, height: 300)),
                    CGRect(x: 100, y: 100, width: 200, height: 100), "center: its own size")
            t.equal(P.shrink.pictureRect(picture: picture, screen: CGSize(width: 400, height: 300)),
                    CGRect(x: 100, y: 100, width: 200, height: 100), "shrink: never larger")
            t.equal(P.shrink.pictureRect(picture: picture, screen: screen), CGRect(x: 0, y: 25, width: 100, height: 50))
            t.equal(P.fill.pictureRect(picture: .zero, screen: screen), .zero)
            t.equal(P.fill.pictureRect(picture: picture, screen: .zero), .zero)
            t.equal(P.fill.pictureRect(picture: CGSize(width: CGFloat.nan, height: 1), screen: screen), .zero)
        }
    }

    // MARK: Guarded folders

    static func protectedTests(_ t: AppTestRunner) {
        t.suite("App: Chameleon desktop: folders macOS asks about are never read") {
            // A home folder of its own: the real Desktop, Documents and Downloads are never touched.
            let home = t.temporaryDirectory("chameleon-home").resolvingSymlinksInPath().path
            let fm = FileManager.default
            for folder in ["Desktop", "Documents", "Downloads", "Pictures", "Library/Mobile Documents"] {
                try fm.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true)
            }
            try Data([1]).write(to: URL(fileURLWithPath: home + "/Pictures/plain.png"))
            try Data([1]).write(to: URL(fileURLWithPath: home + "/Desktop/wall.png"))
            try fm.createSymbolicLink(atPath: home + "/Pictures/link.png", withDestinationPath: home + "/Desktop/wall.png")
            try fm.createSymbolicLink(atPath: home + "/Pictures/relative.png", withDestinationPath: "../Downloads/x.png")
            try fm.createSymbolicLink(atPath: home + "/Pictures/Docs", withDestinationPath: home + "/Documents")
            try fm.createSymbolicLink(atPath: home + "/Pictures/ok.png", withDestinationPath: "plain.png")
            try fm.createSymbolicLink(atPath: home + "/Pictures/loopA", withDestinationPath: "loopB")
            try fm.createSymbolicLink(atPath: home + "/Pictures/loopB", withDestinationPath: "loopA")

            func guards(_ path: String) -> Bool { ProtectedLocations.guards(path, home: home) }
            t.check(guards(home + "/Desktop/wall.png"), "Desktop")
            t.check(guards(home + "/Documents/a.heic"), "Documents")
            t.check(guards(home + "/Downloads/a.jpg"), "Downloads")
            t.check(guards(home + "/Desktop"), "the folder itself")
            t.check(guards(home + "/Library/Mobile Documents/com~apple~CloudDocs/a.jpg"), "iCloud Drive")
            t.check(guards(home + "/Library/CloudStorage/Dropbox/a.jpg"), "cloud storage")
            t.check(guards(home.uppercased() + "/DESKTOP/a.png") || !ProtectedLocations.isInside(home + "/x", home: home),
                    "case does not matter")
            t.check(ProtectedLocations.isInside(home.lowercased() + "/desktop/a.png", home: home))
            t.check(ProtectedLocations.isInside("/System/Volumes/Data" + home + "/Documents/a.png", home: home),
                    "the data volume's name for the same folder")
            t.check(!ProtectedLocations.isInside(home + "/Desktop2/a.png", home: home), "a folder that starts alike")
            t.check(!guards(home + "/Pictures/plain.png"), "Pictures is not guarded")
            t.check(guards(home + "/Pictures/link.png"), "a link into Desktop")
            t.check(guards(home + "/Pictures/relative.png"), "a relative link into Downloads")
            t.check(guards(home + "/Pictures/Docs/a.png"), "a linked folder that is Documents")
            t.check(!guards(home + "/Pictures/ok.png"), "a link that stays outside")
            t.check(guards(home + "/Pictures/loopA"), "a loop counts as guarded")
            t.check(!guards(home + "/Pictures/../Pictures/./plain.png"), "dots")
            t.check(guards(home + "/Pictures/../Desktop/x.png"), "dots into Desktop")
            t.check(!guards("/System/Library/Desktop Pictures/Sonoma.heic"), "the system's pictures")
            t.check(!guards("relative/path.png"), "not a full path")
            t.check(!guards(""))
            t.check(!guards("/Volumes/Deskset Self Test No Such Disk/a.png"), "a volume that is not there cannot ask")
            // The startup disk's entry in /Volumes is a link to /.
            if let link = try? fm.contentsOfDirectory(atPath: "/Volumes").first(where: {
                (try? fm.destinationOfSymbolicLink(atPath: "/Volumes/" + $0)) == "/"
            }) {
                t.check(!guards("/Volumes/\(link)/System/Library/Desktop Pictures/Sonoma.heic"), "the startup disk")
            }
        }
    }

    // MARK: Dynamic pictures

    static func dynamicTests(_ t: AppTestRunner) {
        t.suite("App: Chameleon desktop: a dynamic picture's light and dark pictures") {
            let frames = DynamicWallpaper.frames(fromBase64:count:)
            t.check(frames(base64Plist(["l": 0, "d": 1]), 2).map { $0 == (0, 1) } == true, "apr")
            t.check(frames(base64Plist(["ap": ["l": 3, "d": 7], "si": [["i": 0]]]), 16).map { $0 == (3, 7) } == true,
                    "solar and h24 keep them in ap")
            t.check(frames(base64Plist(["l": 0, "d": 2]), 2) == nil, "a picture the file does not have")
            t.check(frames(base64Plist(["l": -1, "d": 0]), 2) == nil)
            t.check(frames(base64Plist(["l": 0]), 2) == nil, "both are needed")
            t.check(frames(base64Plist(["l": "0", "d": "1"]), 2) == nil, "numbers only")
            t.check(frames("not base 64!", 2) == nil)
            t.check(frames(Data("<plist>".utf8).base64EncodedString(), 2) == nil)

            let folder = t.temporaryDirectory("chameleon-dynamic")
            let apr = folder.appendingPathComponent("apr.tiff")
            dynamicPicture(apr, light: 0, dark: 1)
            let swapped = folder.appendingPathComponent("swapped.tiff")
            dynamicPicture(swapped, light: 1, dark: 0, key: "h24", nested: true)
            let plain = folder.appendingPathComponent("plain.png")
            try halves(plain)
            func source(_ url: URL) -> CGImageSource? { CGImageSourceCreateWithURL(url as CFURL, nil) }
            guard let a = source(apr), let s = source(swapped), let p = source(plain) else {
                t.check(false, "test pictures")
                return
            }
            t.check(DynamicWallpaper.appearanceFrames(a).map { $0 == (0, 1) } == true)
            t.equal(DynamicWallpaper.frame(of: a, dark: false), 0)
            t.equal(DynamicWallpaper.frame(of: a, dark: true), 1)
            t.equal(DynamicWallpaper.frame(of: s, dark: true), 0, "h24, nested")
            t.equal(DynamicWallpaper.frame(of: s, dark: false), 1)
            t.check(DynamicWallpaper.appearanceFrames(p) == nil, "a plain picture")
            t.equal(DynamicWallpaper.frame(of: p, dark: true), 0)

            // The decoded picture is the appearance's, and is kept: a second skin, or a move, decodes nothing.
            let images = WallpaperImages()
            let light = images.picture(file: apr.path, modified: 1, dark: false)
            let dark = images.picture(file: apr.path, modified: 1, dark: true)
            t.equal(light?.frame, 0)
            t.equal(dark?.frame, 1)
            t.equal(images.decodedCount, 2)
            _ = images.picture(file: apr.path, modified: 1, dark: true)
            t.equal(images.decodedCount, 2, "kept")
            _ = images.picture(file: apr.path, modified: 2, dark: true)
            t.equal(images.decodedCount, 3, "a new date decodes again")
            _ = images.picture(file: plain.path, modified: 1, dark: false)
            t.equal(images.decodedCount, 3, "at most three kept")
            t.check(images.picture(file: folder.appendingPathComponent("missing.png").path, modified: 0, dark: false) == nil)
            t.equal(light?.pointSize, CGSize(width: 16, height: 16))

            // macOS's own dynamic picture, where the Mac has it.
            let sonoma = "/System/Library/Desktop Pictures/Sonoma.heic"
            if FileManager.default.fileExists(atPath: sonoma), let src = source(URL(fileURLWithPath: sonoma)) {
                t.check(DynamicWallpaper.appearanceFrames(src).map { $0 == (0, 1) } == true, "Sonoma: light 0, dark 1")
            }
        }
    }

    // MARK: Sampler

    static func samplerTests(_ t: AppTestRunner) {
        t.suite("App: Chameleon desktop: the part of the screen under a window") {
            let left = ScreenDesktop(picture: "", frame: .zero, area: CGRect(x: 0, y: 0, width: 100, height: 100))
            let right = ScreenDesktop(picture: "b", frame: .zero, area: CGRect(x: 100, y: -20, width: 200, height: 100))
            t.equal(DesktopSampler.screen(for: CGRect(x: 80, y: 0, width: 40, height: 10), in: [left, right])?.picture,
                    "", "most of it on the left")
            t.equal(DesktopSampler.screen(for: CGRect(x: 90, y: 0, width: 40, height: 10), in: [left, right])?.picture,
                    "b", "most of it on the right")
            t.equal(DesktopSampler.screen(for: CGRect(x: 500, y: 0, width: 10, height: 10), in: [left, right])?.picture,
                    "b", "off every screen: the nearest")
            t.check(DesktopSampler.screen(for: .zero, in: []) == nil)
            t.equal(DesktopSampler.region(of: CGRect(x: 110, y: 0, width: 50, height: 50), on: right),
                    CGRect(x: 10, y: 20, width: 50, height: 50), "screen points")
            t.equal(DesktopSampler.region(of: CGRect(x: 90, y: -30, width: 50, height: 50), on: right),
                    CGRect(x: 0, y: 0, width: 40, height: 40), "clipped to the screen")
            t.equal(DesktopSampler.region(of: CGRect(x: 900, y: 0, width: 50, height: 50), on: right),
                    CGRect(x: 0, y: 0, width: 200, height: 100), "off it: the whole screen")

            // A 200 × 100 picture, black on the left, white on the right, on a screen of the same size.
            let folder = t.temporaryDirectory("chameleon-sampler")
            let file = folder.appendingPathComponent("halves.png")
            try halves(file)
            guard let picture = WallpaperImages().picture(file: file.path, modified: 0, dark: false) else {
                t.check(false, "decoded")
                return
            }
            let screen = CGRect(x: 0, y: 0, width: 200, height: 100)
            var desktop = ScreenDesktop(picture: file.path, frame: screen, area: screen)
            func luminance(_ window: CGRect) -> Double? {
                DesktopSampler.pixels(picture, desktop: desktop, window: window).flatMap(ChameleonPalette.analyze)?.luminance
            }
            t.close(luminance(CGRect(x: 10, y: 10, width: 60, height: 60)) ?? -1, 0, accuracy: 0.01, "over black")
            t.close(luminance(CGRect(x: 130, y: 10, width: 60, height: 60)) ?? -1, 1, accuracy: 0.01, "over white")
            t.close(luminance(CGRect(x: 50, y: 0, width: 100, height: 100)) ?? -1, 0.5, accuracy: 0.03, "half and half")
            // A second screen to the left: the same picture there, in its own coordinates.
            desktop.area = CGRect(x: -200, y: 0, width: 200, height: 100)
            t.close(luminance(CGRect(x: -60, y: 10, width: 40, height: 40)) ?? -1, 1, accuracy: 0.01, "screen to the left")
            desktop.area = screen

            // Fit on a square screen: black bands above and below; the fill color when macOS gives one.
            desktop.area = CGRect(x: 0, y: 0, width: 200, height: 200)
            desktop.placement = .fit
            desktop.fillColor = ChameleonColor(r: 255, g: 0, b: 0)
            t.close(luminance(CGRect(x: 0, y: 0, width: 200, height: 40)) ?? -1, 0.2126, accuracy: 0.01, "the fill band")
            t.close(luminance(CGRect(x: 150, y: 100, width: 40, height: 40)) ?? -1, 1, accuracy: 0.01, "the picture")
            desktop.fillColor = nil
            t.close(luminance(CGRect(x: 0, y: 0, width: 200, height: 40)) ?? -1, 0, accuracy: 0.01, "black by default")
            // Stretch: the picture covers the square screen; its right half is white.
            desktop.placement = .stretch
            t.close(luminance(CGRect(x: 150, y: 0, width: 40, height: 200)) ?? -1, 1, accuracy: 0.01, "stretch")
            // Center at 144 dpi: 100 × 50 points in the middle of the screen.
            let retina = folder.appendingPathComponent("retina.png")
            try halves(retina, dpi: 144)
            if let small = WallpaperImages().picture(file: retina.path, modified: 0, dark: false) {
                t.equal(small.pointSize, CGSize(width: 100, height: 50))
                desktop.placement = .center
                desktop.fillColor = ChameleonColor(r: 255, g: 255, b: 255)
                let l = DesktopSampler.pixels(small, desktop: desktop, window: CGRect(x: 55, y: 80, width: 40, height: 40))
                    .flatMap(ChameleonPalette.analyze)?.luminance ?? -1
                t.close(l, 0, accuracy: 0.01, "centred: the black half at x 50 to 100, y 75 to 125")
            }
            // A desktop of one color.
            let solid = ScreenDesktop(picture: "", frame: screen, area: screen, solid: ChameleonColor(r: 255, g: 255, b: 255))
            t.close(DesktopSampler.pixels(nil, desktop: solid, window: CGRect(x: 0, y: 0, width: 10, height: 10))
                .flatMap(ChameleonPalette.analyze)?.luminance ?? -1, 1, accuracy: 0.001)
            t.check(DesktopSampler.pixels(nil, desktop: desktop, window: screen) == nil, "no picture, nothing")
            // Small: at most 96 pixels on the long side.
            let many = DesktopSampler.pixels(picture, desktop: desktop, window: CGRect(x: 0, y: 0, width: 2000, height: 20))
            t.check((many?.count ?? 0) <= 96 * 96, "\(many?.count ?? 0) pixels")
        }
    }

    // MARK: The measure

    static func measureTests(_ t: AppTestRunner) {
        t.suite("App: Chameleon desktop: the measure samples under its window and tells its children") {
            let folder = t.temporaryDirectory("chameleon-measure")
            let file = folder.appendingPathComponent("halves.png")
            try halves(file)
            let screen = CGRect(x: 0, y: 0, width: 200, height: 100)
            try withDesktops([ScreenDesktop(picture: file.path, frame: screen, area: screen)]) {
                let (skin, host) = try MediaUITests.bareSkin(t, """
                    [Rainmeter]
                    Update=1000
                    SkinWidth=60
                    SkinHeight=60

                    [Variables]
                    Changes=0

                    [MeasureWall]
                    Measure=Plugin
                    Plugin=Chameleon
                    Type=Desktop
                    CropDesktop=Skin
                    UpdateDivider=5

                    [MeasureLum]
                    Measure=Plugin
                    Plugin=Chameleon
                    Parent=MeasureWall
                    Color=Luminance
                    UpdateDivider=5
                    DynamicVariables=1
                    OnChangeAction=[!SetVariable Changes "(#Changes# + 1)"]

                    [MeasureByBang]
                    Measure=Plugin
                    Plugin=Chameleon
                    Parent=MeasureWall
                    Color=Luminance
                    UpdateDivider=-1

                    [MeterBox]
                    Meter=Image
                    W=60
                    H=60
                    """)
                host.windowOrigin = CGPoint(x: 10, y: 10)
                skin.update()
                guard let wall = skin.measure(named: "MeasureWall") as? ChameleonMeasure,
                      let lum = skin.measure(named: "MeasureLum"), let byBang = skin.measure(named: "MeasureByBang") else {
                    t.check(false, "measures")
                    return
                }
                t.check(wall.samplesUnderSkin)
                t.check(!wall.followsWindow, "no window to follow off screen")
                t.close(lum.value, 0.02, accuracy: 0.001, "the fallback until the sample is in")
                // The children update when the sample comes in, before the skin's next update.
                t.check(AppSelfTest.spin(timeout: 10) { lum.value < 0.005 }, "over the black half: \(lum.value)")
                t.close(byBang.value, 0.02, accuracy: 1e-9, "a child updated only by bangs is left alone")
                t.equal(skin.variable("Changes"), "1", "OnChangeAction ran once")
                t.equal(wall.pluginString, file.path, "the parent's string is the picture")

                // The window moves over the white half: sampled again at once, not at the next check 2 s later.
                host.windowOrigin = CGPoint(x: 130, y: 10)
                wall.windowSettled()
                t.check(AppSelfTest.spin(timeout: 10) { lum.value > 0.99 }, "over the white half: \(lum.value)")
                t.equal(skin.variable("Changes"), "2")
                // Two moves in a row: the second one waits for the first sample, then runs.
                host.windowOrigin = CGPoint(x: 10, y: 10)
                wall.windowSettled()
                host.windowOrigin = CGPoint(x: 70, y: 10)
                wall.windowSettled()
                t.check(AppSelfTest.spin(timeout: 10) { abs(lum.value - 0.5) < 0.05 }, "the last place wins: \(lum.value)")
                // A move to a place that looks the same changes nothing.
                host.windowOrigin = CGPoint(x: 10, y: 10)
                wall.windowSettled()
                t.check(AppSelfTest.spin(timeout: 10) { lum.value < 0.005 }, "back over black: \(lum.value)")
                let changes = skin.variable("Changes")
                host.windowOrigin = CGPoint(x: 11, y: 12)
                wall.windowSettled()
                RenderCommand.wait(milliseconds: 500)
                t.equal(skin.variable("Changes"), changes, "same colors, no update")
                skin.close()
                wall.windowSettled()
            }

            // CropDesktop=1 and 0 are as before: the picture as the screen shows it, or all of it.
            try withDesktops([ScreenDesktop(picture: file.path, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                            area: CGRect(x: 0, y: 0, width: 100, height: 100))]) {
                let (skin, _) = try MediaUITests.bareSkin(t)
                let wall = ChameleonMeasure(name: "Wall", section: MediaUITests.section("Wall", [("CropDesktop", "1")]),
                                            skin: skin, type: "chameleon")
                wall.readOptions()
                _ = wall.computeValue()
                t.check(AppSelfTest.spin(timeout: 10) { wall.palette != nil }, "sampled")
                t.close(wall.palette?.luminance ?? -1, 0.5, accuracy: 0.05, "the centre square: half and half")
            }
        }

        t.suite("App: Chameleon desktop: a dynamic picture and a guarded one") {
            let folder = t.temporaryDirectory("chameleon-measure-dynamic")
            let file = folder.appendingPathComponent("dynamic.tiff")
            dynamicPicture(file, light: 0, dark: 1)
            let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
            let saved = NSApp.appearance
            t.atSuiteEnd {
                NSApp.appearance = saved
                MacAppearance.current.refresh()
                DesktopInputs.appearance.refresh()
            }
            for crop in ["Skin", "1", "0"] {
                for dark in [false, true] {
                    RenderCommand.applyAppearance(dark ? .dark : .light)
                    try withDesktops([ScreenDesktop(picture: file.path, frame: screen, area: screen)]) {
                        let (skin, host) = try MediaUITests.bareSkin(t)
                        defer { withExtendedLifetime(host) {} }
                        let wall = ChameleonMeasure(name: "Wall", section: MediaUITests.section("Wall", [
                            ("CropDesktop", crop),
                        ]), skin: skin, type: "chameleon")
                        wall.readOptions()
                        _ = wall.computeValue()
                        t.check(AppSelfTest.spin(timeout: 10) { wall.palette != nil }, "sampled")
                        let l = wall.palette?.luminance ?? -1
                        t.check(dark ? l < 0.05 : l > 0.7, "CropDesktop=\(crop), \(dark ? "dark" : "light"): \(l)")
                    }
                }
            }
            RenderCommand.applyAppearance(.light)

            // Kept in Desktop: not read (not even looked at), the fallback colors apply. The path is only a name here.
            let guarded = NSHomeDirectory() + "/Desktop/Deskset self-test wallpaper that does not exist.png"
            for crop in ["Skin", "1"] {
                try withDesktops([ScreenDesktop(picture: guarded, frame: screen, area: screen)]) {
                    let (skin, host) = try MediaUITests.bareSkin(t)
                    let wall = ChameleonMeasure(name: "Wall", section: MediaUITests.section("Wall", [
                        ("CropDesktop", crop), ("FallbackBG1", "123456"),
                    ]), skin: skin, type: "chameleon")
                    wall.readOptions()
                    _ = wall.computeValue()
                    t.check(AppSelfTest.spin(timeout: 10) { wall.skippedProtected }, "skipped (CropDesktop=\(crop))")
                    t.check(wall.palette == nil)
                    t.equal(wall.effectivePalette.background1, ChameleonColor(hex: "123456"))
                    t.equal(wall.imagePath, guarded, "the string is still the setting")
                    t.equal(host.logs.filter { $0.contains("not read") }.count, 1, "said once")
                }
            }
        }

        t.suite("App: Chameleon desktop: a widget samples again when its window moves") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            defer { app.stopAllForTermination() }
            let folder = t.temporaryDirectory("chameleon-live")
            let file = folder.appendingPathComponent("halves.png")
            try halves(file, width: 400, height: 200)
            // The primary screen, as the skin's environment gives it, shows the halves: black left, white right.
            let primary = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let area = CGRect(origin: .zero, size: primary.size)
            let skinFolder = app.skinsDirectory.appendingPathComponent("Probe", isDirectory: true)
            try FileManager.default.createDirectory(at: skinFolder, withIntermediateDirectories: true)
            try """
                [Rainmeter]
                Update=600000
                SkinWidth=40
                SkinHeight=40

                [MeasureWall]
                Measure=Plugin
                Plugin=Chameleon
                CropDesktop=Skin

                [MeasureLum]
                Measure=Plugin
                Plugin=Chameleon
                Parent=MeasureWall
                Color=Luminance

                [MeterBox]
                Meter=Image
                W=40
                H=40
                """.write(to: skinFolder.appendingPathComponent("Probe.ini"), atomically: true, encoding: .utf8)
            app.rescanLibrary()
            try withDesktops([ScreenDesktop(picture: file.path, frame: primary, area: area)]) {
                guard let c = app.activate(config: "Probe", file: "Probe.ini") else {
                    t.check(false, "the skin loads")
                    return
                }
                let skin: Skin = c.skin
                // Left half, near the top.
                c.window.setFrameOrigin(NSPoint(x: primary.minX + 20, y: primary.maxY - 80))
                guard let wall = skin.measure(named: "MeasureWall") as? ChameleonMeasure,
                      let lum = skin.measure(named: "MeasureLum") else {
                    t.check(false, "measures")
                    return
                }
                t.check(AppSelfTest.spin(timeout: 10) { wall.followsWindow }, "it follows the widget's window")
                t.check(AppSelfTest.spin(timeout: 10) { lum.value < 0.01 }, "over black: \(lum.value)")
                let updates = skin.updateCount
                // Dragged to the right half: sampled again once it stops, without an update of the skin.
                c.window.setFrameOrigin(NSPoint(x: primary.maxX - 80, y: primary.maxY - 80))
                t.check(AppSelfTest.spin(timeout: 10) { lum.value > 0.99 }, "over white: \(lum.value)")
                t.equal(skin.updateCount, updates, "no skin update needed")
                t.check(!c.window.isVisible, "never shown")
                app.deactivate(config: "Probe")
                t.check(AppSelfTest.spin(timeout: 5) { !wall.followsWindow }, "let go when the skin closes")
            }
        }

        t.suite("App: Chameleon desktop: moves are followed until the moves stop") {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 50, height: 50), styleMask: .borderless,
                                  backing: .buffered, defer: true)
            var calls = 0
            let watch = WindowMoveWatch(window: window, delay: 0.05) { calls += 1 }
            window.setFrameOrigin(NSPoint(x: 120, y: 100))
            window.setFrameOrigin(NSPoint(x: 140, y: 100))
            window.setFrameOrigin(NSPoint(x: 160, y: 100))
            t.check(watch.isPending, "waiting for the moves to stop")
            t.check(AppSelfTest.spin(timeout: 5) { calls > 0 }, "called")
            RenderCommand.wait(milliseconds: 100)
            t.equal(calls, 1, "once for the three moves")
            watch.stop()
            window.setFrameOrigin(NSPoint(x: 10, y: 10))
            RenderCommand.wait(milliseconds: 100)
            t.equal(calls, 1, "stopped")
            t.check(!window.isVisible, "never shown")
        }
    }

    // MARK: Render command

    static func renderTests(_ t: AppTestRunner) {
        t.suite("App: Chameleon desktop: --wallpaper, --at and --screen") {
            let o = RenderOptions.parse(["--render", "a.ini", "--wallpaper", "w.heic", "--at", "100, 250.5",
                                         "--screen", "1440x900"])
            t.equal(o?.wallpaper, "w.heic")
            t.equal(o?.at, CGPoint(x: 100, y: 250.5))
            t.equal(o?.screen, CGSize(width: 1440, height: 900))
            t.equal(o?.warnings ?? ["x"], [])
            t.equal(o?.standInDesktop?.picture, URL(fileURLWithPath: "w.heic").standardizedFileURL.path)
            t.equal(o?.standInDesktop?.area, CGRect(x: 0, y: 0, width: 1440, height: 900))
            let d = RenderOptions.parse(["--render", "a.ini"])
            t.equal(d?.at, .zero)
            t.equal(d?.screen, RenderOptions.standardScreen)
            t.check(d?.standInDesktop == nil, "the Mac's own desktop")
            let b = RenderOptions.parse(["--render", "a.ini", "--background", "250,250,250"])
            t.equal(b?.standInDesktop?.solid, ChameleonColor(r: 250, g: 250, b: 250), "a desktop of that color")
            let bad = RenderOptions.parse(["--render", "a.ini", "--at", "x", "--screen", "0x5", "--wallpaper"])
            t.equal(bad?.at, .zero)
            t.equal(bad?.screen, RenderOptions.standardScreen)
            t.equal(bad?.wallpaper, nil)
            t.equal(bad?.warnings.count, 3)
            t.equal(CommandLineTools.validate(["Deskset", "--render", "a.ini", "--wallpaper", "w", "--at", "1,2", "--screen", "3x4"]),
                    .mode)
            t.check(CommandLineTools.usage.contains("--wallpaper"))

            // A frameless piece over the halves: its luminance follows where it sits.
            let saved = NSApp.appearance
            t.atSuiteEnd {
                NSApp.appearance = saved
                MacAppearance.current.refresh()
                DesktopInputs.appearance.refresh()
            }
            let folder = t.temporaryDirectory("chameleon-render")
            let wallpaper = folder.appendingPathComponent("halves.png")
            try halves(wallpaper, width: 400, height: 200)
            let skinFolder = folder.appendingPathComponent("Skins/Probe", isDirectory: true)
            try FileManager.default.createDirectory(at: skinFolder, withIntermediateDirectories: true)
            let ini = skinFolder.appendingPathComponent("Probe.ini")
            try """
                [Rainmeter]
                Update=1000
                SkinWidth=40
                SkinHeight=40

                [MeasureWall]
                Measure=Plugin
                Plugin=Chameleon
                CropDesktop=Skin

                [MeasureLum]
                Measure=Plugin
                Plugin=Chameleon
                Parent=MeasureWall
                Color=Luminance
                OnChangeAction=[!WriteKeyValue Variables Lum "[MeasureLum:3]" "#CURRENTPATH#Lum.inc"]

                [MeterBox]
                Meter=Image
                W=40
                H=40
                """.write(to: ini, atomically: true, encoding: .utf8)
            for (x, expected) in [(20.0, 0.0), (300.0, 1.0)] {
                try "[Variables]\n".write(to: skinFolder.appendingPathComponent("Lum.inc"), atomically: true,
                                          encoding: .utf8)
                let out = folder.appendingPathComponent("probe-\(Int(x)).png")
                let status = RenderCommand.run(["--render", ini.path, "--out", out.path, "--wallpaper", wallpaper.path,
                                                "--screen", "400x200", "--at", "\(x),20", "--updates", "2",
                                                "--interval", "300"])
                t.equal(status, 0)
                let written = (try? String(contentsOf: skinFolder.appendingPathComponent("Lum.inc"), encoding: .utf8)) ?? ""
                t.check(written.contains("Lum=\(expected == 0 ? "0.000" : "1.000")"), "at x \(x): \(written)")
                // The wallpaper is drawn behind the skin, where it sits.
                if let rep = NSImage(contentsOf: out)?.representations.first as? NSBitmapImageRep,
                   let c = rep.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB) {
                    t.close(Double(c.redComponent), expected, accuracy: 0.05, "drawn behind at x \(x)")
                } else {
                    t.check(false, "output \(out.lastPathComponent)")
                }
                try? FileManager.default.removeItem(at: skinFolder.appendingPathComponent("Lum.inc"))
            }
            t.check(DesktopInputs.fake.current == nil, "the stand-in goes with the render")
            t.equal(RenderCommand.run(["--render", ini.path, "--out", folder.appendingPathComponent("x.png").path,
                                       "--wallpaper", folder.appendingPathComponent("missing.png").path]), 1)
        }
    }
}
