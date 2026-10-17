import AppKit
import DesksetCore

/// The Studio window's canvas: the backdrop (the desktop picture read without ever asking macOS for permission, the
/// workbench), the other widgets around it, the preview bar (the Mac's look, glass, sample data and a frozen time in
/// the Studio's instance only, Interact), the zoom capsule and Actual Size.
enum Studio2PreviewSelfTests {
    static func run(_ t: AppTestRunner) {
        privacyTests(t)
        backdropTests(t)
        previewTests(t)
        wordsTests(t)
    }

    // MARK: The desktop picture, safely

    /// A file system of made-up entries that records every path it is asked about.
    final class FakeReader: WallpaperFileReader {
        var entries: [String: WallpaperFileEntry] = [:]
        var folders: [String: [String]] = [:]
        var counts: [String: Int] = [:]
        private(set) var touched: [String] = []
        private(set) var opened: [String] = []

        func entry(atPath path: String) -> WallpaperFileEntry {
            touched.append(path)
            return entries[path] ?? .missing
        }

        func names(inFolder path: String) -> [String] {
            touched.append(path)
            return folders[path] ?? []
        }

        func picture(atPath path: String, maxPixels: Int) -> (image: CGImage, count: Int)? {
            opened.append(path)
            guard entries[path] == .file, let image = StudioWallpapers.image(.bright, size: CGSize(width: 8, height: 4),
                                                                            scale: 1) else { return nil }
            return (image, counts[path] ?? 1)
        }

        /// Adds `path` and every folder above it.
        func add(_ path: String, _ entry: WallpaperFileEntry = .file) {
            var parts = path.split(separator: "/").map(String.init)
            entries[path] = entry
            parts.removeLast()
            var current = ""
            for part in parts {
                current += "/" + part
                if entries[current] == nil { entries[current] = .folder }
            }
        }
    }

    static func privacyTests(_ t: AppTestRunner) {
        t.suite("Studio2: canvas: which desktop pictures may be read") {
            let privacy = WallpaperPrivacy(home: "/Users/tester")
            let guarded = [
                "/Users/tester/Desktop/a.jpg", "/Users/tester/Documents/x/y.heic", "/Users/tester/Downloads/z.png",
                "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/w.jpg",
                "/Users/tester/Library/CloudStorage/Dropbox/w.jpg", "/Users/tester/Library/Containers/app/w.jpg",
                "/Users/tester/Library/Group Containers/g/w.jpg", "/Volumes/USB/w.jpg", "/Volumes/Share",
                "/Network/Servers/nas/w.jpg", "/net/nas/w.jpg", "/Users/other/Pictures/w.jpg",
                "/Users/tester/Pictures/Photos Library.photoslibrary/originals/w.jpg",
                "/System/Volumes/Data/Users/tester/Desktop/w.jpg", "/Users/tester/Pictures/../Desktop/w.jpg",
                "/users/tester/desktop/w.jpg", "/Users/tester/Desktop",
            ]
            for path in guarded { t.check(privacy.isGuarded(path), "guarded: \(path)") }
            let readable = [
                "/Users/tester/Pictures/w.jpg", "/System/Library/Desktop Pictures/Sequoia.heic",
                "/Library/Desktop Pictures/x.jpg", "/Users/Shared/w.jpg",
                "/Users/tester/Library/Application Support/Wallpapers/x.jpg", "/Users/tester", "/Users",
                "/Users/tester/DesktopPictures/x.jpg",
            ]
            for path in readable { t.check(!privacy.isGuarded(path), "readable: \(path)") }
            t.equal(WallpaperPrivacy.normalized("/System/Volumes/Data/Users/a/./b/../c.jpg"), "/Users/a/c.jpg")
            t.equal(WallpaperPrivacy.normalized("/Library/Desktop Pictures/"), "/Library/Desktop Pictures")
        }

        t.suite("Studio2: canvas: a desktop picture in a guarded place is never opened") {
            let privacy = WallpaperPrivacy(home: "/Users/tester")
            func resolve(_ path: String, _ reader: FakeReader) -> WallpaperResolution {
                let result = WallpaperResolver.resolve(path, privacy: privacy, reader: reader)
                for touched in reader.touched {
                    t.check(!privacy.isGuarded(touched), "\(path): never looked at \(touched)")
                }
                return result
            }
            // A picture file: read as it is.
            var reader = FakeReader()
            reader.add("/Users/tester/Pictures/Hills.jpg")
            t.equal(resolve("/Users/tester/Pictures/Hills.jpg", reader), .picture("/Users/tester/Pictures/Hills.jpg",
                                                                                   similar: false))
            // In the Desktop, Documents, Downloads, iCloud, on another volume: nothing is touched at all.
            for path in ["/Users/tester/Desktop/Hills.jpg", "/Users/tester/Documents/Hills.jpg",
                         "/Users/tester/Downloads/Hills.jpg", "/Users/tester/Library/Mobile Documents/x/Hills.jpg",
                         "/Volumes/Photos/Hills.jpg", "/Network/nas/Hills.jpg"] {
                reader = FakeReader()
                reader.add(path)
                t.equal(resolve(path, reader), .sample, path)
                t.check(!reader.touched.contains(where: { $0.hasPrefix(path) || $0 == path }), "\(path) not touched")
                t.equal(reader.opened, [], "\(path) not opened")
            }
            // A link from an ordinary folder into a guarded one: followed only as far as the guard.
            reader = FakeReader()
            reader.add("/Users/tester/Pictures/Link.jpg", .link("/Users/tester/Documents/Hills.jpg"))
            reader.add("/Users/tester/Documents/Hills.jpg")
            t.equal(resolve("/Users/tester/Pictures/Link.jpg", reader), .sample, "a link into Documents")
            t.equal(reader.opened, [])
            // A folder of the path is a link into the Desktop.
            reader = FakeReader()
            reader.add("/Users/tester/Pictures/Walls", .link("../Desktop/Walls"))
            reader.add("/Users/tester/Desktop/Walls/Hills.jpg")
            t.equal(resolve("/Users/tester/Pictures/Walls/Hills.jpg", reader), .sample, "a folder linked into Desktop")
            t.equal(reader.opened, [])
            // A relative link inside an ordinary folder: followed.
            reader = FakeReader()
            reader.add("/Users/tester/Pictures/Link.jpg", .link("Real.jpg"))
            reader.add("/Users/tester/Pictures/Real.jpg")
            t.equal(resolve("/Users/tester/Pictures/Link.jpg", reader), .picture("/Users/tester/Pictures/Real.jpg",
                                                                                  similar: false))
            // A rotating folder: its first picture by name, "similar".
            reader = FakeReader()
            reader.add("/Users/tester/Pictures/Rotation", .folder)
            reader.folders["/Users/tester/Pictures/Rotation"] = ["b.jpg", "notes.txt", ".hidden.jpg", "a 10.png",
                                                                 "a 9.png"]
            for name in ["b.jpg", "notes.txt", ".hidden.jpg", "a 10.png", "a 9.png"] {
                reader.add("/Users/tester/Pictures/Rotation/" + name)
            }
            t.equal(resolve("/Users/tester/Pictures/Rotation", reader),
                    .picture("/Users/tester/Pictures/Rotation/a 9.png", similar: true), "the first by name, similar")
            // A moving (aerial) wallpaper: a sample; a still of one: similar.
            reader = FakeReader()
            reader.add("/Library/Application Support/Wallpapers/Clouds.mov")
            t.equal(resolve("/Library/Application Support/Wallpapers/Clouds.mov", reader), .sample, "a video")
            reader.add("/Library/Application Support/Aerials/thumbnails/Clouds.png")
            t.equal(resolve("/Library/Application Support/Aerials/thumbnails/Clouds.png", reader),
                    .picture("/Library/Application Support/Aerials/thumbnails/Clouds.png", similar: true))
            // Links in a circle, a missing file, nothing set.
            reader = FakeReader()
            reader.add("/Users/tester/Pictures/A.jpg", .link("B.jpg"))
            reader.add("/Users/tester/Pictures/B.jpg", .link("A.jpg"))
            t.equal(resolve("/Users/tester/Pictures/A.jpg", reader), .sample, "links in a circle")
            t.equal(resolve("/Users/tester/Pictures/Missing.jpg", FakeReader()), .sample, "a missing file")
            t.equal(resolve("", FakeReader()), .sample, "nothing set")
        }

        t.suite("Studio2: canvas: reading the desktop picture") {
            let source = WallpaperSource()
            source.privacy = WallpaperPrivacy(home: "/Users/tester")
            let reader = FakeReader()
            source.reader = reader
            source.queue = nil
            reader.add("/Users/tester/Pictures/Hills.jpg")
            reader.add("/System/Library/Desktop Pictures/Dynamic.heic")
            reader.counts["/System/Library/Desktop Pictures/Dynamic.heic"] = 16
            reader.add("/Users/tester/Desktop/Hills.jpg")
            func setting(_ path: String) -> WallpaperSetting {
                WallpaperSetting(path: path, screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), screenScale: 2)
            }
            var readies = 0
            let exact = source.wallpaper(for: setting("/Users/tester/Pictures/Hills.jpg"), dark: false) { readies += 1 }
            t.equal(exact?.fidelity, .exact)
            t.check(exact?.image != nil, "the picture")
            t.equal(readies, 1, "told once it was read")
            t.equal(reader.opened, ["/Users/tester/Pictures/Hills.jpg"])
            _ = source.wallpaper(for: setting("/Users/tester/Pictures/Hills.jpg"), dark: false) { readies += 1 }
            t.equal(reader.opened.count, 1, "kept: not read again")
            let dynamic = source.wallpaper(for: setting("/System/Library/Desktop Pictures/Dynamic.heic"), dark: false) {}
            t.equal(dynamic?.fidelity, .similar, "a dynamic wallpaper: similar")
            let guarded = source.wallpaper(for: setting("/Users/tester/Desktop/Hills.jpg"), dark: true) {}
            t.equal(guarded?.fidelity, .close, "on the Desktop: a sample")
            t.check(guarded?.image == nil)
            t.equal(guarded?.sample, .dusk, "the sample closest to a dark Mac")
            t.equal(source.wallpaper(for: setting("/Users/tester/Desktop/Hills.jpg"), dark: false) {}?.sample, .bright)
            t.check(!reader.opened.contains("/Users/tester/Desktop/Hills.jpg"), "never opened")
            t.check(!reader.touched.contains(where: { source.privacy.isGuarded($0) }), "nothing guarded looked at")
            t.equal(StudioPreviewBar.fidelityWord(.close), "Close to your wallpaper")
            t.equal(StudioPreviewBar.fidelityWord(.similar), "Similar")
            t.equal(StudioPreviewBar.fidelityWord(.exact), nil)
        }

        t.suite("Studio2: canvas: how macOS lays the picture out") {
            let screen = CGSize(width: 1000, height: 800)
            let pixels = CGSize(width: 4000, height: 2000)
            t.equal(WallpaperLayout.rect(picturePixels: pixels, pictureScale: 2, screen: screen,
                                         scaling: .scaleProportionallyUpOrDown, allowsClipping: true),
                    CGRect(x: -300, y: 0, width: 1600, height: 800), "Fill Screen: clipped")
            t.equal(WallpaperLayout.rect(picturePixels: pixels, pictureScale: 2, screen: screen,
                                         scaling: .scaleProportionallyUpOrDown, allowsClipping: false),
                    CGRect(x: 0, y: 150, width: 1000, height: 500), "Fit to Screen: the fill color around")
            t.equal(WallpaperLayout.rect(picturePixels: pixels, pictureScale: 2, screen: screen,
                                         scaling: .scaleAxesIndependently, allowsClipping: true),
                    CGRect(origin: .zero, size: screen), "Stretch")
            t.equal(WallpaperLayout.rect(picturePixels: pixels, pictureScale: 2, screen: screen, scaling: .scaleNone,
                                         allowsClipping: true),
                    CGRect(x: -500, y: -100, width: 2000, height: 1000), "Centre: its own size")
            t.equal(WallpaperLayout.rect(picturePixels: CGSize(width: 400, height: 200), pictureScale: 2, screen: screen,
                                         scaling: .scaleProportionallyDown, allowsClipping: true),
                    CGRect(x: 400, y: 350, width: 200, height: 100), "down only: a small picture stays small")
            // The widget's real frame is drawn at the card; the rest of the desktop around it the same way.
            let mapping = DesktopMapping(widgetFrame: CGRect(x: 100, y: 500, width: 200, height: 100),
                                         cardRect: CGRect(x: 300, y: 200, width: 400, height: 200), zoom: 2)
            t.equal(mapping.viewRect(forScreenRect: CGRect(x: 100, y: 500, width: 200, height: 100)),
                    CGRect(x: 300, y: 200, width: 400, height: 200), "the widget at the card")
            t.equal(mapping.viewRect(forScreenRect: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                    CGRect(x: 100, y: -200, width: 2000, height: 1600), "its screen around it")
        }
    }

    // MARK: Backdrops

    static func backdropTests(_ t: AppTestRunner) {
        t.suite("Studio2: canvas: backdrops") {
            // The samples are drawn, the same on every run.
            func bytes(_ sample: StudioSample) -> Data? {
                guard let image = StudioWallpapers.image(sample, size: CGSize(width: 120, height: 80), scale: 1),
                      let data = image.dataProvider?.data else { return nil }
                return data as Data
            }
            for sample in [StudioSample.dawn, .dusk] {
                let first = bytes(sample)
                t.check(first != nil, "\(sample) is drawn")
                // Drawn again, not from the cache.
                let ctx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.translateBy(x: 0, y: 80)
                ctx.scaleBy(x: 1, y: -1)
                StudioWallpapers.draw(sample, in: CGRect(x: 0, y: 0, width: 120, height: 80), ctx)
                let again = ctx.makeImage()?.dataProvider?.data as Data?
                t.equal(again, first, "\(sample): the same picture every time")
            }
            t.check(bytes(.dawn) != bytes(.dusk), "dawn and dusk differ")
            t.check(StudioSample.dusk.isDark && !StudioSample.dawn.isDark)
            // What the menu offers.
            t.equal(StudioBackdropKind.offered(reduceTransparency: false),
                    [.desktop, .workbench, .transparent], "Solid only with Reduce Transparency")
            t.equal(StudioBackdropKind.offered(reduceTransparency: true).last, .solid)
            t.equal(StudioBackdropKind.allCases.map(\.title),
                    ["Your Desktop", "Workbench", "Transparent", "Solid"])
            // Every kind draws something.
            let view = StudioBackdropView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            view.usesStandInDesktop = true
            for kind in StudioBackdropKind.allCases {
                view.kind = kind
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    t.check(false, "\(kind) caches")
                    continue
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                let color = rep.colorAt(x: 100, y: 60)
                t.check((color?.alphaComponent ?? 0) > 0.99, "\(kind) fills the canvas")
            }
        }

        t.suite("Studio2: canvas: the other widgets come from their windows, never from their skins") {
            let window = NSPanel(contentRect: NSRect(x: 900, y: 300, width: 60, height: 40),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = SkinContentView(frame: NSRect(x: 0, y: 0, width: 60, height: 40))
            content.wantsLayer = true
            window.contentView = content
            let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 20))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 20, width: 60, height: 20))
            let frameLayer = CALayer()
            frameLayer.frame = CGRect(x: 0, y: 0, width: 60, height: 40)
            frameLayer.contents = ctx.makeImage()
            frameLayer.contentsScale = 1
            content.layer?.addSublayer(frameLayer)
            let neighbour = StudioNeighbourCapture.capture(window)
            t.equal(neighbour.frame, window.frame)
            guard let image = neighbour.image else { return t.check(false, "the layer's picture is taken") }
            let rep = NSBitmapImageRep(cgImage: image)
            t.check((rep.colorAt(x: 2, y: 2)?.redComponent ?? 0) > 0.9, "upright: red at the top")
            t.check((rep.colorAt(x: 2, y: rep.pixelsHigh - 3)?.blueComponent ?? 0) > 0.9, "blue at the bottom")

            // A window that only draws when asked: nothing is taken, and it is not asked to draw.
            final class CountingView: NSView {
                var draws = 0
                override func draw(_ dirtyRect: NSRect) { draws += 1 }
            }
            let other = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 30, height: 30), styleMask: [.borderless],
                                backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            let counting = CountingView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
            counting.wantsLayer = true
            other.contentView = counting
            let drawsBefore = counting.draws
            let blank = StudioNeighbourCapture.capture(other)
            t.check(blank.image == nil, "no picture without drawing")
            t.equal(counting.draws, drawsBefore, "the window was not asked to draw")

            // Around the widget: clear at 100 %, faded elsewhere.
            let view = StudioNeighboursView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            view.neighbours = [neighbour, blank]
            view.mapping = DesktopMapping(widgetFrame: CGRect(x: 800, y: 300, width: 50, height: 50),
                                          cardRect: CGRect(x: 50, y: 50, width: 50, height: 50), zoom: 1)
            t.check(!view.isFaded)
            view.mapping?.zoom = 2
            t.check(view.isFaded, "faded when not at 100 %")
            window.close()
            other.close()
        }
    }

    // MARK: The preview bar

    static let ruleIni = """
        [Rainmeter]
        Update=1000

        [Variables]
        Hot=224,76,62
        Ink=34,34,38

        [MeasureCPU]
        Measure=CPU
        IfCondition=MeasureCPU > 99.9
        IfTrueAction=[!SetOption MeterValue FontColor "#Hot#"]
        IfFalseAction=[!SetOption MeterValue FontColor "#Ink#"]

        [MeasureTime]
        Measure=Time
        Format=%H:%M

        [MeterValue]
        Meter=String
        MeasureName=MeasureCPU
        Text=%1%
        NumOfDecimals=0
        FontColor=#Ink#
        W=120
        H=30

        [MeterTime]
        Meter=String
        MeasureName=MeasureTime
        Y=30
        W=120
        H=20

        [MeterMode]
        Meter=String
        Text=#MACDARKMODE#
        Y=50
        W=120
        H=20

        """

    static func previewTests(_ t: AppTestRunner) {
        t.suite("Studio2: canvas: the preview's look, backdrop and glass") {
            Studio2SelfTests.prepare(t)
            guard let (app, c, _) = try Studio2SelfTests.loadSkin(t, "Look", ruleIni) else { return }
            guard let studio = Studio2SelfTests.openNew(app, c), let preview = studio.preview else {
                return t.check(false, "the window opens")
            }
            preview.macIsDark = { false }
            let canvas = studio.canvasController
            t.equal(canvas.previewBar.appearanceItem.prefix, "Preview:")
            t.equal(canvas.previewBar.appearanceItem.title, "Light Mode")
            // The popover: titled "Preview only"; no language row for INI; the footer.
            preview.showPreviewPopover()
            guard let popover = preview.previewPopoverContent else { return t.check(false, "the popover's content") }
            _ = popover.view
            t.equal(popover.titleLabel.stringValue, "Preview only")
            t.equal(popover.footerLabel.stringValue, "Preview only — your widget doesn’t change.")
            t.equal((0..<popover.appearanceControl.segmentCount).map { popover.appearanceControl.label(forSegment: $0) },
                    ["Follow Mac", "Light", "Dark"])
            t.equal((0..<popover.glassControl.segmentCount).map { popover.glassControl.label(forSegment: $0) },
                    ["Default", "Clear", "Tinted (Mac setting)"])
            t.check(!allText(in: popover.view).contains("Language"), "no language row for an INI widget")
            // Dark: the canvas and the instance's appearance variables.
            let before = studio.skin
            popover.appearanceControl.selectedSegment = 2
            popover.changed()
            t.equal(preview.state.appearance, .dark)
            t.equal(canvas.view.appearance?.name, .darkAqua, "the canvas looks dark")
            t.check(studio.skin !== before, "the instance loaded again with the look")
            t.equal((studio.skin?.meter(named: "MeterMode") as? StringMeter)?.text, "1", "#MACDARKMODE# is 1 there")
            t.equal(canvas.previewBar.appearanceItem.title, "Dark Mode")
            t.check(canvas.previewBar.appearanceItem.isOn, "not the Mac's: in the accent color")
            popover.glassControl.selectedSegment = 1
            popover.changed()
            t.equal(preview.state.glass, .clear)
            let region = GlassRegion(id: "a", rect: SkinRect(x: 0, y: 0, width: 10, height: 10))
            t.equal(preview.state.previewed([region], dark: false).first?.style, .clear)
            preview.setGlass(.tinted)
            t.check(preview.state.previewed([region], dark: false).first?.tint != nil, "tinted")
            preview.setAppearance(.followMac)
            preview.setGlass(.standard)
            t.check(canvas.view.appearance == nil, "the Mac's look again")
            t.check(studio.session?.host.appearance == nil)

            // The backdrop: remembered for the user (in memory while headless), the menu, Show Other Widgets.
            let defaultsBefore = UserDefaults.standard.string(forKey: StudioPreferences.backdropKey)
            preview.setBackdrop(.workbench)
            t.equal(canvas.backdropView.kind, .workbench)
            t.equal(preview.preferences.backdrop, .workbench)
            t.equal(UserDefaults.standard.string(forKey: StudioPreferences.backdropKey), defaultsBefore,
                    "the user's own settings are not touched headless")
            t.equal(canvas.previewBar.backdropItem.title, "Workbench")
            t.check(!canvas.previewBar.backdropItem.isOn, "a place to work, not a preset of the preview")
            let menu = preview.menus.backdropMenu(preview.state, fidelity: .close, reduceTransparency: false,
                                                  canShowNeighbours: true, neighboursShown: false)
            t.equal(menu.items.filter { $0.state == .on }.map(\.title), ["Workbench"])
            t.check(menu.items.contains { $0.title == "Show Other Widgets" })
            t.check(!menu.items.contains { $0.title == "Solid" })
            if let desktop = menu.items.first(where: { $0.representedObject as? String == "desktop" }) {
                preview.menus.backdropChosen(desktop)
            }
            t.equal(preview.state.backdrop, .desktop)
            t.check(canvas.backdropView.usesStandInDesktop, "headless: the stand-in hills, never the real picture")
            t.equal(preview.wallpapers.requests, 0, "the desktop picture was never asked for")
            t.equal(canvas.previewBar.backdropItem.suffix, nil, "the stand-in counts as exact")

            // The glass plane holds the widget's glass at the zoom; the canvas draws none itself.
            t.equal(canvas.canvas.glassDrawing, SkinRenderer.GlassDrawing.none)
            t.check(canvas.glassPlane.usesStandIns, "stand-ins headless")
        }

        t.suite("Studio2: canvas: caption and zoom capsule") {
            Studio2SelfTests.prepare(t)
            t.equal(StudioSizeName.caption(zoom: 1.65, file: "Medium.ini", onDesktop: true, actualSize: false),
                    "Preview 165% · Medium on your desktop")
            t.equal(StudioSizeName.caption(zoom: 2.5, file: "CPU.ini", onDesktop: true, actualSize: false),
                    "Preview 250% · 100% on your desktop")
            t.equal(StudioSizeName.caption(zoom: 2.5, file: "small.ini", onDesktop: false, actualSize: false),
                    "Preview 250% · Small · not on your desktop yet")
            t.equal(StudioSizeName.caption(zoom: 1, file: "Large.ini", onDesktop: true, actualSize: true),
                    "Actual size · where it is on your desktop")

            guard let (app, c, _) = try Studio2SelfTests.loadSkin(t, "Zoom", ruleIni) else { return }
            guard let studio = Studio2SelfTests.openNew(app, c), let preview = studio.preview else {
                return t.check(false, "the window opens")
            }
            let canvas = studio.canvasController
            // Actual Size: 100 %, the caption says where it is, the other widgets around it.
            studio.actualSizeClicked()
            t.equal(canvas.canvas.zoom, 1)
            t.equal(canvas.captionTag.text, "Actual size · where it is on your desktop")
            t.equal(canvas.zoomCapsule.percentItem.title, "100%")
            t.check(preview.showsNeighbours, "the neighbours are on at 100 %")
            t.equal(canvas.backdropView.mapping?.widgetFrame, c.window.frame, "the backdrop lined up with the widget")
            studio.zoomInClicked()
            t.equal(canvas.canvas.zoom, 2)
            t.equal(canvas.zoomCapsule.percentItem.title, "200%")
            t.check(canvas.captionTag.text.hasPrefix("Preview 200% · 100% on your desktop"), canvas.captionTag.text)
            t.check(!preview.showsNeighbours, "not at 200 % unless asked")
            preview.setShowsNeighbours(true)
            t.check(preview.showsNeighbours, "asked")
            t.check(canvas.neighboursView.isFaded, "faded at 200 %")
            studio.zoomOutClicked()
            t.equal(canvas.canvas.zoom, 1)
            canvas.zoomCapsule.zoomInItem.perform()
            t.equal(canvas.canvas.zoom, 2, "the capsule's +")
            canvas.zoomCapsule.actualSizeItem.perform()
            t.equal(canvas.canvas.zoom, 1, "the capsule's Actual Size")
        }
    }

    /// Every string of the labels and controls under `view`.
    static func allText(in view: NSView) -> String {
        var words: [String] = []
        if let field = view as? NSTextField { words.append(field.stringValue) }
        if let control = view as? NSSegmentedControl {
            words += (0..<control.segmentCount).compactMap { control.label(forSegment: $0) }
        }
        for sub in view.subviews { words.append(allText(in: sub)) }
        return words.joined(separator: " ")
    }

    // MARK: Words

    static let bannedEnglish = ["skin", "skins", "meter", "meters", "measure", "measures", "section", "variable",
                                "variables", "computed", "modifier", "binding", "freeform", "ini", "ms", "try", "ink"]

    static func wordsTests(_ t: AppTestRunner) {
        t.suite("Studio2: canvas: words") {
            let prefixes = ["backdrop.", "preview.", "data.", "capsule.", "zoom", "caption.", "size."]
            for key in StudioText.Key.allCases where prefixes.contains(where: { key.rawValue.hasPrefix($0) }) {
                guard let entry = StudioText.table[key] else { continue }
                let words = entry.lowercased().components(separatedBy: CharacterSet.letters.inverted)
                for banned in bannedEnglish where words.contains(banned) {
                    t.check(false, "\(key.rawValue): “\(banned)” in “\(entry)”")
                }
            }
        }
    }
}
