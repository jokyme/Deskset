import AppKit
import DesksetCore

/// The new Studio window's canvas: the backdrop (the desktop picture read without ever asking macOS for permission, the
/// samples, the workbench), the other widgets around it, the preview bar (the Mac's look, glass, sample data and a
/// frozen time in the Studio's instance only, Interact), the zoom capsule, Actual Size and Show on Desktop.
enum Studio2PreviewSelfTests {
    static func run(_ t: AppTestRunner) {
        privacyTests(t)
        backdropTests(t)
        previewTests(t)
        interactTests(t)
        desktopTests(t)
        snapshotTests(t)
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
            for sample in [StudioSample.dawn, .dusk, .bright, .busy] {
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
            t.check(StudioSample.dusk.isDark && StudioSample.busy.isDark && !StudioSample.bright.isDark)
            // What the menu offers.
            t.equal(StudioBackdropKind.offered(reduceTransparency: false),
                    [.desktop, .bright, .busy, .dark, .workbench, .transparent], "Solid only with Reduce Transparency")
            t.equal(StudioBackdropKind.offered(reduceTransparency: true).last, .solid)
            t.equal(StudioBackdropKind.allCases.map(\.title),
                    ["Your Desktop", "Bright", "Busy", "Dark", "Workbench", "Transparent", "Solid"])
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
            view.kind = .dark
            t.check(view.showsDarkBackdrop, "Dark is dark")
            view.kind = .bright
            t.check(!view.showsDarkBackdrop)
        }

        t.suite("Studio2: canvas: the other widgets come from their windows, never from their skins") {
            // A window whose content holds a finished picture in a layer (a skin's frames, drawn on its own thread).
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
        t.suite("Studio2: canvas: sample data in the Studio's instance only") {
            Studio2SelfTests.prepare(t)
            guard let (app, c, url) = try Studio2SelfTests.loadSkin(t, "Sample", ruleIni) else { return }
            guard let studio = Studio2SelfTests.openNew(app, c), let preview = studio.preview else {
                return t.check(false, "the new window opens")
            }
            let fileBefore = Studio2SelfTests.read(url)
            t.check(studio.session?.measureValues === preview.sample, "the session holds the sample data")
            t.check(studio.skin?.measureValues === preview.sample, "the Studio's instance takes it")
            t.check(c.skin.measureValues == nil, "the desktop copy has none")
            t.equal(preview.state.dataLabel, "Live")
            t.check(studio.canvasController.statusCapsule.isHidden, "no capsule while live")

            // 100 %: the rule turns the number red in the Studio's instance; the desktop copy stays as it is.
            preview.setData(.level(1))
            let meter = { studio.skin?.meter(named: "MeterValue") }
            t.equal(studio.skin?.measure(named: "MeasureCPU")?.value, 100)
            t.equal(meter()?.string("FontColor"), "224,76,62", "the rule fired: red")
            t.equal((meter() as? StringMeter)?.text, "100%")
            c.skin.update()
            t.check((c.skin.measure(named: "MeasureCPU")?.value ?? 100) < 100, "the desktop copy reads the Mac")
            t.equal(c.skin.meter(named: "MeterValue")?.string("FontColor"), "34,34,38", "and stays dark")
            t.equal(Studio2SelfTests.read(url), fileBefore, "nothing written")
            // The bar says so.
            let bar = studio.canvasController.previewBar
            t.equal(bar.dataItem.title, "100 %")
            t.check(bar.dataItem.isOn, "in the accent color")
            t.check(!bar.backToLiveItem.isHidden, "Back to Live")
            t.check(!studio.canvasController.statusCapsule.isHidden, "the capsule over the canvas")
            t.equal(studio.canvasController.statusCapsule.messageItem.title,
                    "Previewing sample data 100 % · your desktop doesn’t change")
            // A reload of the Studio's instance keeps it.
            studio.session?.reloadStudioSkin()
            t.check(studio.skin?.measureValues === preview.sample, "a new instance takes it too")
            t.equal(studio.skin?.measure(named: "MeasureCPU")?.value, 100)

            // Frozen time.
            preview.setTime(.frozen(StudioScreen.frozenTime))
            t.equal(preview.state.dataLabel, "100 % · 10:09")
            t.equal((studio.skin?.meter(named: "MeterTime") as? StringMeter)?.text, "10:09")
            c.skin.update()
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            t.check((c.skin.meter(named: "MeterTime") as? StringMeter)?.text != "10:09"
                    || clock.string(from: Date()) == "10:09", "the desktop copy keeps the clock")
            // The menu and Back to Live.
            let menu = preview.menus.dataMenu(preview.state)
            let checked = menu.items.filter { $0.state == .on }.map(\.title)
            t.equal(checked, ["100 %", "Frozen at 10:09"], "what is in use is checked")
            t.check(menu.items.contains { $0.title == "Back to Live" })
            bar.backToLiveItem.perform()
            t.equal(preview.state.data, .live)
            t.equal(preview.state.time, .live)
            t.check(!preview.sample.isActive, "live again")
            t.equal(meter()?.string("FontColor"), "34,34,38", "the rule's other action")
            t.check(bar.backToLiveItem.isHidden && studio.canvasController.statusCapsule.isHidden, "nothing to say")
            // Paused, no data, through the menu's own items.
            guard let paused = preview.menus.dataMenu(preview.state).items.first(where: { $0.title == "Paused" }),
                  let none = preview.menus.dataMenu(preview.state).items.first(where: { $0.title == "No Data" }) else {
                return t.check(false, "the menu's items")
            }
            preview.menus.dataChosen(paused)
            t.equal(preview.state.data, .paused)
            t.equal(bar.dataItem.title, "Paused")
            preview.menus.dataChosen(none)
            t.equal(studio.skin?.measure(named: "MeasureCPU")?.value, 0)
            preview.backToLive()
            studio.window?.close()
            t.check(c.skin.measureValues == nil)
        }

        t.suite("Studio2: canvas: the preview's look, backdrop and glass") {
            Studio2SelfTests.prepare(t)
            guard let (app, c, _) = try Studio2SelfTests.loadSkin(t, "Look", ruleIni) else { return }
            guard let studio = Studio2SelfTests.openNew(app, c), let preview = studio.preview else {
                return t.check(false, "the new window opens")
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
            t.check(canvas.previewBar.backdropItem.isOn)
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

        t.suite("Studio2: canvas: caption, zoom capsule and narrow canvases") {
            Studio2SelfTests.prepare(t)
            t.equal(StudioSizeName.caption(zoom: 1.65, file: "Medium.ini", onDesktop: true, actualSize: false),
                    "Preview 165% · Medium on your desktop")
            t.equal(StudioSizeName.caption(zoom: 2.5, file: "CPU.ini", onDesktop: true, actualSize: false),
                    "Preview 250% · 100% on your desktop")
            t.equal(StudioSizeName.caption(zoom: 2.5, file: "small.ini", onDesktop: false, actualSize: false),
                    "Preview 250% · Small · not on your desktop yet")
            t.equal(StudioSizeName.caption(zoom: 1, file: "Large.ini", onDesktop: true, actualSize: true),
                    "Actual size · where it is on your desktop")
            StudioText.languageOverride = .chinese
            t.equal(StudioSizeName.caption(zoom: 1.65, file: "Medium.ini", onDesktop: true, actualSize: false),
                    "预览 165% · 桌面上是中号")
            t.equal(StudioSizeName.caption(zoom: 1.5, file: "Nocturne.ini", onDesktop: true, actualSize: false),
                    "预览 150% · 桌面上是 100%")
            StudioText.languageOverride = .english

            guard let (app, c, _) = try Studio2SelfTests.loadSkin(t, "Zoom", ruleIni) else { return }
            guard let studio = Studio2SelfTests.openNew(app, c), let preview = studio.preview else {
                return t.check(false, "the new window opens")
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

            // Wide: every word. Narrower: the zoom capsule's words shorten first, then the backdrop's go.
            let window = studio.window!
            func layout(_ width: CGFloat) {
                window.setContentSize(NSSize(width: width, height: 860))
                window.contentView?.layoutSubtreeIfNeeded()
                canvas.layoutFloating()
            }
            layout(1400)
            t.check(!canvas.zoomCapsule.compact && !canvas.previewBar.compact, "1400: every word")
            t.equal(canvas.zoomCapsule.actualSizeItem.title, "Actual Size")
            var sawZoomOnly = false
            for width in stride(from: 1400, through: 900, by: -20) {
                layout(CGFloat(width))
                if canvas.previewBar.compact { t.check(canvas.zoomCapsule.compact, "\(width): the zoom words go first") }
                if canvas.zoomCapsule.compact && !canvas.previewBar.compact { sawZoomOnly = true }
                t.check(canvas.previewBar.appearanceItem.showsTitle && canvas.previewBar.interactItem.showsTitle,
                        "\(width): Preview: and Interact keep their words")
                let bar = canvas.previewBar.frame, pill = canvas.zoomCapsule.frame
                t.check(!bar.intersects(pill), "\(width): the bar clears the capsule")
            }
            t.check(sawZoomOnly, "a width where only the zoom capsule shortens")
            layout(900)
            t.equal(canvas.zoomCapsule.actualSizeItem.title, "1:1")
            t.equal(canvas.zoomCapsule.desktopItem.title, "Desktop")
            t.check(!canvas.previewBar.backdropItem.showsTitle, "the backdrop's words went")
            layout(1400)
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

    // MARK: Interact

    static let interactIni = """
        [Rainmeter]
        Update=1000

        [Variables]
        Clicked=0

        [MeterButton]
        Meter=String
        Text=Clicked #Clicked#
        DynamicVariables=1
        W=120
        H=40
        SolidColor=0,0,0,1
        LeftMouseUpAction=[!SetVariable Clicked 1]["https://www.example.com/page"][!ActivateConfig "Studio2\\Elsewhere"]

        """

    static func interactTests(_ t: AppTestRunner) {
        t.suite("Studio2: canvas: Interact") {
            Studio2SelfTests.prepare(t)
            guard let (app, c, _) = try Studio2SelfTests.loadSkin(t, "Interact", interactIni) else { return }
            guard let studio = Studio2SelfTests.openNew(app, c), let preview = studio.preview,
                  let session = studio.session else {
                return t.check(false, "the new window opens")
            }
            let canvas = studio.canvasController
            let overlay = canvas.interactionView
            // `hitTest` takes a point of the overlay's superview: the pane, where the card is.
            let inside = NSPoint(x: canvas.cardRect.midX, y: canvas.cardRect.midY)
            t.check(overlay.hitTest(inside) == nil, "designing: the canvas takes the pointer")
            t.check(!session.host.takesPointer)

            // On (⌥⌘P): the Studio's instance takes the pointer.
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "π", charactersIgnoringModifiers: "p",
                                       isARepeat: false, keyCode: 35)!
            t.check(preview.keyEquivalent(key), "⌥⌘P")
            t.check(preview.state.interacting, "on")
            t.check(session.host.takesPointer, "the host says the window takes the pointer")
            t.check(canvas.previewBar.interactItem.isOn, "Interact in the accent color")
            t.check(overlay.hitTest(inside) === overlay, "interacting: the overlay takes the pointer")
            session.host.policy.clearRecorded()

            // A click: what stays inside happens, what reaches outside is only recorded and offered.
            overlay.click(x: 10, y: 10)
            t.equal(studio.skin?.variable("Clicked"), "1", "the click reached the Studio's instance")
            t.equal(c.skin.variable("Clicked"), "0", "not the desktop copy")
            let recorded = session.host.policy.recorded
            t.equal(recorded.map(\.kind), [.execute, .bang], "the web page and the other widget: recorded")
            t.equal(recorded.first?.name, "https://www.example.com/page")
            t.check(app.controller(for: "Studio2\\Elsewhere") == nil, "no other widget was loaded")
            t.equal(preview.heldAction?.sentence, "Would run !ActivateConfig Studio2\\Elsewhere")
            t.equal(StudioHeldAction(recorded[0]).sentence, "Would open example.com")
            t.equal(StudioHeldAction(recorded[0]).button, "Open")
            t.check(!canvas.statusCapsule.isHidden, "the capsule offers it")
            t.equal(canvas.statusCapsule.actionItem.title, "Run")
            t.equal(StudioHeldAction.displayName(of: "/System/Applications/Utilities/Activity Monitor.app"),
                    "Activity Monitor")

            // Off (Esc): the canvas designs again.
            overlay.onEscape?()
            t.check(!preview.state.interacting)
            t.check(!session.host.takesPointer)
            t.check(overlay.hitTest(inside) == nil)
            t.check(preview.heldAction == nil && canvas.statusCapsule.isHidden, "the offer goes")
            // While designing, what the instance holds back is not offered.
            overlay.click(x: 10, y: 10)
            t.check(preview.heldAction == nil)
        }
    }

    // MARK: Show on Desktop

    static func desktopTests(_ t: AppTestRunner) {
        t.suite("Studio2: canvas: Show on Desktop") {
            Studio2SelfTests.prepare(t)
            let motion = StudioMotion.reduceOverride
            StudioMotion.reduceOverride = true
            t.atSuiteEnd { StudioMotion.reduceOverride = motion }
            guard let (app, c, _) = try Studio2SelfTests.loadSkin(t, "Peek", Studio2SelfTests.ini) else { return }
            guard let studio = Studio2SelfTests.openNew(app, c), let preview = studio.preview,
                  let window = studio.window else {
                return t.check(false, "the new window opens")
            }
            let desktop = preview.desktopView
            let widget = c.window
            let level = widget.level
            t.check(desktop.canShow, "the widget is on the desktop")
            t.check(studio.canvasController.zoomCapsule.desktopItem.isEnabled)
            studio.canvasController.zoomCapsule.desktopItem.perform()
            t.check(desktop.isShowing, "the capsule's Show on Desktop")
            t.equal(window.alphaValue, StudioDesktopView.fadedAlpha, "the Studio window fades (at once: Reduce Motion)")
            t.equal(widget.level, StudioDesktopView.raisedLevel, "the widget comes to the front")
            t.check(studio.canvasController.zoomCapsule.desktopItem.isOn)
            let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                       isARepeat: false, keyCode: 53)!
            t.check(desktop.handle(esc), "Esc")
            t.check(!desktop.isShowing)
            t.equal(widget.level, level, "the widget's own level again")
            t.equal(window.alphaValue, 1, "the Studio window at full strength")

            // ⇧⌘D: a press switches; again switches back.
            let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                            timestamp: 0, windowNumber: 0, context: nil, characters: "D",
                                            charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2)!
            t.check(preview.keyEquivalent(shortcut), "⇧⌘D")
            t.check(desktop.isShowing)
            desktop.releasedKey(at: ProcessInfo.processInfo.systemUptime)
            t.check(desktop.isShowing, "let go at once: it stays")
            t.check(desktop.handle(shortcut), "⇧⌘D again")
            t.check(!desktop.isShowing)
            t.equal(widget.level, level)
            // Held: a peek.
            t.check(preview.keyEquivalent(shortcut))
            desktop.releasedKey(at: ProcessInfo.processInfo.systemUptime + StudioDesktopView.peekHold + 0.1)
            t.check(!desktop.isShowing, "let go after a hold: back")
            t.equal(window.alphaValue, 1)
            t.equal(widget.level, level)
            // A widget that floats above everything keeps its own level while shown, and after.
            widget.level = .statusBar
            desktop.show()
            t.equal(widget.level, .statusBar, "not lowered")
            desktop.back()
            t.equal(widget.level, .statusBar)
            widget.level = level
            // Closing the window while it shows comes back first.
            desktop.show()
            window.close()
            t.check(!desktop.isShowing, "closed: back")
            t.equal(widget.level, level)
        }

        t.suite("Studio2: canvas: Reduce Motion") {
            let motion = StudioMotion.reduceOverride
            defer { StudioMotion.reduceOverride = motion }
            StudioMotion.reduceOverride = true
            var ran = false, done = false
            StudioMotion.animate(0.5, { animated in ran = !animated }, done: { done = true })
            t.check(ran && done, "at once, and done at once")
        }
    }

    // MARK: The designed screens

    static func snapshotTests(_ t: AppTestRunner) {
        t.suite("Studio2: canvas: the designed screens") {
            Studio2SelfTests.prepare(t)
            guard let screen = StudioScreen.named("03-customize"), let opened = StudioSnapshot.open(screen) else {
                return t.check(false, "03 opens")
            }
            let canvas = opened.controller.canvasController
            t.equal(canvas.backdropView.kind, .desktop)
            t.check(canvas.backdropView.usesStandInDesktop, "the stand-in hills")
            t.equal(canvas.captionTag.text, "Preview 165% · Medium on your desktop")
            t.check(!canvas.captionTag.isHidden, "the caption shows")
            t.check(canvas.statusCapsule.isHidden, "no capsule: live")
            t.equal(canvas.previewBar.backdropItem.title, "Your Desktop")
            t.equal(canvas.previewBar.dataItem.title, "Live")
            t.equal(canvas.zoomCapsule.percentItem.title, "165%")
            let bar = canvas.previewBar.frame, pill = canvas.zoomCapsule.frame
            t.check(bar.maxX < pill.minX, "the bar clears the zoom capsule")
            t.equal(bar.midY.rounded(), (canvas.view.bounds.height - 34).rounded(), "34 pt from the bottom")
            t.equal(pill.maxX, canvas.view.bounds.width - 16, "16 pt from the right")
            t.equal((opened.controller.skin?.meter(named: "MeterCPUValue") as? StringMeter)?.text ?? "21%", "21%",
                    "the suite's sample readings")
            let image = StudioSnapshot.render(opened.controller)
            t.equal(image?.pixelsWide, 2800)
            opened.close()

            guard let preview = StudioScreen.named("10-preview"), let ten = StudioSnapshot.open(preview) else {
                return t.check(false, "10 opens")
            }
            let c10 = ten.controller.canvasController
            t.equal(c10.backdropView.kind, .bright)
            t.equal(c10.previewBar.backdropItem.title, "Bright")
            t.check(c10.previewBar.backdropItem.isOn && c10.previewBar.dataItem.isOn, "presets in the accent color")
            t.equal(c10.previewBar.dataItem.title, "100 % · 10:09")
            t.check(!c10.previewBar.backToLiveItem.isHidden, "Back to Live")
            t.check(!c10.statusCapsule.isHidden)
            t.equal(c10.statusCapsule.messageItem.title, "Previewing sample data 100 % · your desktop doesn’t change")
            t.check(ten.controller.preview.previewPopoverContent != nil, "the popover is composed")
            t.equal((ten.controller.skin?.meter(named: "MeterValue") as? StringMeter)?.text, "100%")
            t.equal(ten.controller.skin?.meter(named: "MeterValue")?.string("FontColor"), "224,76,62", "red")
            t.check(StudioSnapshot.render(ten.controller) != nil)
            ten.close()
        }
    }
}
