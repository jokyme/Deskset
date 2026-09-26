import AppKit
import DesksetCore

/// The Mac look extensions as the app draws them (docs/compat/engine.md): the system font designs, SF Symbols as
/// images, the appearance variables and the refresh when the appearance changes. The engine's side is in the core
/// tests (MacLookTests.swift).
enum MacLookSelfTests {
    static func run(_ t: AppTestRunner) {
        fontTests(t)
        symbolTests(t)
        appearanceTests(t)
    }

    // MARK: Helpers

    /// A skin written to a temporary folder, loaded and updated once with the app's own host (`RenderHost`).
    private static func loadSkin(_ t: AppTestRunner, _ ini: String, label: String) throws -> (Skin, RenderHost)? {
        let skins = t.temporaryDirectory(label).appendingPathComponent("Skins")
        let folder = skins.appendingPathComponent("Look/Test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Test.ini")
        try ini.write(to: url, atomically: true, encoding: .utf8)
        let host = RenderHost()
        let skin = Skin(config: "Look\\Test", fileURL: url, skinsDirectory: skins, system: SystemMonitor.shared,
                        host: host)
        try skin.load()
        skin.update()
        return (skin, host)
    }

    /// Draws `skin` at `scale` device pixels per point (as `--render` does) into an RGBA bitmap.
    private static func draw(_ skin: Skin, scale: CGFloat) -> NSBitmapImageRep? {
        let width = Int((CGFloat(skin.width) * scale).rounded(.up)), height = Int((CGFloat(skin.height) * scale).rounded(.up))
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: width, height: height))
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        SkinRenderer.draw(skin, in: cg)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// RGBA (0…255, not premultiplied) of the pixels of `rep` inside `rect` (pixels, top-left origin).
    private static func pixels(_ rep: NSBitmapImageRep, in rect: CGRect? = nil) -> [(r: Int, g: Int, b: Int, a: Int)] {
        let area = rect ?? CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        var result: [(Int, Int, Int, Int)] = []
        for y in Int(area.minY)..<min(Int(area.maxY), rep.pixelsHigh) {
            for x in Int(area.minX)..<min(Int(area.maxX), rep.pixelsWide) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                result.append((Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                               Int((c.blueComponent * 255).rounded()), Int((c.alphaComponent * 255).rounded())))
            }
        }
        return result
    }

    private static func fontName(_ face: String, weight: Int? = nil, bold: Bool = false, italic: Bool = false)
        -> (name: String, resolved: Fonts.Resolved) {
        let resolved = Fonts.resolve(Fonts.Request(face: face, size: 20, weight: weight, bold: bold, italic: italic))
        return (CTFontCopyPostScriptName(resolved.font) as String, resolved)
    }

    // MARK: Fonts

    static func fontTests(_ t: AppTestRunner) {
        t.suite("App: Mac look: system font designs") {
            // Each name resolves to its design of the system font (unless a family of that name is installed).
            for (face, part) in [("System Rounded", "Rounded"), ("SF Pro Rounded", "Rounded"), ("System Mono", "Monospaced"),
                                 ("SF Mono", "Monospaced"), ("system monospaced", "Monospaced"), ("New York", "NewYork"),
                                 ("System Serif", "NewYork"), ("System", "SFNS")] {
                if Fonts.installedFamily(named: face) != nil {
                    print("    (\(face) is installed on this Mac: the installed family wins)")
                    continue
                }
                let name = fontName(face).name
                t.check(name.contains(part), "\(face) → \(name)")
            }
            t.check(CTFontGetSymbolicTraits(fontName("System Mono").resolved.font).contains(.traitMonoSpace),
                    "the monospaced design is fixed pitch")
            // Weight: FontWeight, StringStyle=Bold and style words in the name.
            t.check(fontName("System Rounded", weight: 700).name.contains("Rounded-Bold"), fontName("System Rounded", weight: 700).name)
            t.check(fontName("System Rounded", bold: true).name.contains("Bold"))
            t.check(fontName("System Rounded Semibold").name.contains("Semibold"), fontName("System Rounded Semibold").name)
            t.check(fontName("New York", weight: 900).name.contains("Black"), fontName("New York", weight: 900).name)
            t.check(fontName("System Mono", weight: 300).name.contains("Light"))
            // Italic: a real italic where the design has one (keeping the weight), slanted where it has none.
            let monoItalic = fontName("System Mono", weight: 700, italic: true)
            t.check(monoItalic.name.contains("BoldItalic"), monoItalic.name)
            t.equal(monoItalic.resolved.slant, 0)
            let serifItalic = fontName("New York Italic")
            t.check(CTFontGetSymbolicTraits(serifItalic.resolved.font).contains(.traitItalic), serifItalic.name)
            let roundedItalic = fontName("System Rounded", italic: true)
            t.check(roundedItalic.resolved.slant > 0, "the rounded design has no italic: slanted")
            let systemBoldItalic = fontName("System", bold: true, italic: true)
            let traits = CTFontGetSymbolicTraits(systemBoldItalic.resolved.font)
            t.check(traits.contains(.traitItalic) && traits.contains(.traitBold), "bold italic keeps the weight: \(systemBoldItalic.name)")
            // The editor's words.
            t.equal(Fonts.substitution(for: "SF Mono"), "System Mono")
            t.equal(Fonts.substitution(for: "new york"), "System Serif")
            t.equal(Fonts.substitution(for: "System"), "System Font")
            t.equal(Fonts.systemDesign(named: " System Rounded "), .rounded)
            t.equal(Fonts.systemDesign(named: "Helvetica"), nil)
            t.check(Fonts.systemFont(design: .serif, size: 13).fontName.contains("NewYork"))
            t.equal(InspectorWindowController.systemDesignFaces.map(\.faceName), ["System Rounded", "System Mono", "System Serif"])
            t.equal(Set(InspectorWindowController.macColorNames.keys),
                    Set(BuiltInVariables.macAppearanceNames.map { $0.lowercased() }.filter { $0.hasSuffix("color") }),
                    "every Mac color has a name in the editor")

            // Measuring uses the design (it is what drawing uses): in the monospaced design every character is as wide.
            guard let (skin, host) = try loadSkin(t, """
            [Rainmeter]
            AccurateText=1
            [Narrow]
            Meter=String
            FontFace=System Mono
            FontSize=12
            Text=iiiiiiii
            [Wide]
            Meter=String
            FontFace=System Mono
            FontSize=12
            Y=20R
            Text=WWWWWWWW
            [Proportional]
            Meter=String
            FontFace=System Rounded
            FontSize=12
            Y=20R
            Text=iiiiiiii
            [Inline]
            Meter=String
            FontFace=Arial
            FontSize=12
            Y=20R
            Text=WWWWWWWW
            InlineSetting=Face | System Mono
            """, label: "fonts") else { return }
            withExtendedLifetime(host) {
                let narrow = skin.meter(named: "Narrow")?.frame.width ?? 0, wide = skin.meter(named: "Wide")?.frame.width ?? -1
                t.check(narrow > 40, "measured: \(narrow)")
                t.close(narrow, wide, accuracy: 1, "monospaced: iiiiiiii is as wide as WWWWWWWW")
                t.check((skin.meter(named: "Proportional")?.frame.width ?? 0) < narrow - 10, "the rounded design is proportional")
                t.close(skin.meter(named: "Inline")?.frame.width ?? 0, wide, accuracy: 1, "InlineSetting=Face uses the design")
                t.check(skin.issues.isEmpty, "\(skin.issues)")
            }
        }
    }

    // MARK: Symbols

    static func symbolTests(_ t: AppTestRunner) {
        t.suite("App: Mac look: SF Symbols are drawn as images") {
            let cpu = MacSymbol(name: "cpu.fill")
            guard let natural = Images.size(atPath: cpu.path) else { return t.check(false, "cpu.fill renders") }
            t.check(natural.width >= 16 && natural.height >= 14 && natural.width == natural.width.rounded(),
                    "whole points near 16: \(natural)")
            let big = MacSymbol(name: "cpu.fill", style: MacSymbol.Style(pointSize: 32))
            t.close(Images.size(atPath: big.path)?.width ?? 0, natural.width * 2, accuracy: 2, "MacSymbolSize scales it")
            // Rendered at a density: more pixels, the same size in points.
            let dense = cpu.withDensity(3)
            t.equal(Images.size(atPath: dense.path).map { [$0.width, $0.height] }, [natural.width, natural.height])
            t.close(Double(Images.cgImage(atPath: dense.path)?.width ?? 0), natural.width * 3, accuracy: 1)
            t.equal(Images.size(atPath: MacSymbol(name: "no.such.symbol.here").path) == nil, true)
            t.check(!SymbolImages.exists("no.such.symbol.here") && SymbolImages.exists("wifi"))
            // The editor's thumbnail: the symbol itself, for every rendering.
            for rendering in MacSymbol.Rendering.allCases {
                let preview = SymbolImages.preview(MacSymbol(name: "wifi", style: MacSymbol.Style(rendering: rendering)))
                t.check((preview?.size.width ?? 0) > 10, "preview \(rendering)")
            }
            t.equal(SymbolImages.preview(MacSymbol(name: "no.such.symbol.here")) == nil, true)

            // Monochrome: white, with the parts the symbol knocks out left transparent.
            let xmark = MacSymbol(name: "xmark.circle.fill", style: MacSymbol.Style(pointSize: 40))
            if let image = Images.cgImage(atPath: xmark.path) {
                let rep = NSBitmapImageRep(cgImage: image)
                let center = rep.colorAt(x: image.width / 2, y: image.height / 2)?.alphaComponent ?? 1
                let ring = rep.colorAt(x: image.width / 2, y: image.height / 8)?.usingColorSpace(.deviceRGB)
                t.check(center < 0.2, "the cross is knocked out: \(center)")
                t.check((ring?.alphaComponent ?? 0) > 0.9 && (ring?.redComponent ?? 0) > 0.95 && (ring?.blueComponent ?? 0) > 0.95,
                        "the disc is white: \(String(describing: ring))")
            } else {
                t.check(false, "xmark.circle.fill renders")
            }

            // Drawn by a skin: tinted, sharp at the drawn size, the options of a picture.
            guard let (skin, host) = try loadSkin(t, """
            [Rainmeter]
            [Red]
            Meter=Image
            ImageName=sf:cpu.fill
            W=64
            H=64
            ImageTint=255,0,0
            [Faded]
            Meter=Image
            ImageName=sf:cpu.fill
            X=70
            ImageTint=0,0,255
            ImageAlpha=128
            [Weather]
            Meter=Image
            ImageName=sf:cloud.sun.fill
            MacSymbolRendering=Multicolor
            MacSymbolSize=40
            X=100
            [Shades]
            Meter=Image
            ImageName=sf:wifi
            MacSymbolRendering=Hierarchical
            X=160
            [Grey]
            Meter=Image
            ImageName=sf:cpu.fill
            Greyscale=1
            X=200
            [Missing]
            Meter=Image
            ImageName=sf:no.such.symbol.here
            X=240
            W=20
            H=20
            SolidColor=0,0,0,0
            """, label: "symbols") else { return }
            withExtendedLifetime(host) {
                t.equal(skin.meter(named: "Red").map { [$0.frame.width, $0.frame.height] }, [64, 64])
                t.equal((skin.meter(named: "Red") as? ImageMeter)?.preserveAspectRatio, 1, "keeps its shape")
                t.check(skin.issues.contains { $0.contains("no.such.symbol.here") }, "\(skin.issues)")
                guard let rep = draw(skin, scale: 2) else { return t.check(false, "draws") }
                let red = pixels(rep, in: CGRect(x: 0, y: 0, width: 128, height: 128)).filter { $0.a > 250 }
                t.check(red.count > 3000, "a big, opaque symbol: \(red.count) pixels")
                t.check(red.allSatisfy { $0.r > 240 && $0.g < 15 && $0.b < 15 }, "tinted red")
                let edge = pixels(rep, in: CGRect(x: 0, y: 0, width: 128, height: 128)).filter { $0.a > 10 && $0.a < 245 }
                t.check(edge.count < red.count / 3, "sharp edges at 2x: \(edge.count) soft pixels")
                let faded = pixels(rep, in: CGRect(x: 140, y: 0, width: 60, height: 60)).filter { $0.a > 0 }
                t.check(!faded.isEmpty && faded.allSatisfy { $0.a <= 130 && $0.b > 240 }, "ImageAlpha fades it")
                let weather = pixels(rep, in: CGRect(x: 200, y: 0, width: 110, height: 110)).filter { $0.a > 250 }
                t.check(weather.contains { $0.r > 200 && $0.g > 140 && $0.b < 80 }, "multicolor: a yellow sun")
                t.check(weather.contains { $0.r > 240 && $0.g > 240 && $0.b > 240 }, "multicolor: a white cloud")
                let grey = pixels(rep, in: CGRect(x: 400, y: 0, width: 60, height: 60)).filter { $0.a > 250 }
                t.check(!grey.isEmpty && grey.allSatisfy { abs($0.r - $0.g) < 3 && abs($0.g - $0.b) < 3 }, "Greyscale")
                // The Red symbol was rendered for the pixels it covers.
                let path = SymbolImages.drawingPath(cpu.path, options: ImageOptions(), drawn: CGSize(width: 64, height: 64),
                                                    fit: true, in: rep.cgContextForTest())
                let expected = ((2 * min(64 / natural.width, 64 / natural.height)) * 8).rounded(.up) / 8
                t.close(MacSymbol(path: path)?.density ?? 0, expected, accuracy: 1e-9, path)
                t.equal(SymbolImages.drawingPath("/tmp/x.png", options: ImageOptions(), drawn: nil, in: rep.cgContextForTest()),
                        "/tmp/x.png", "a file is drawn as it is")
            }

            // Many threads at once render one symbol once and agree on its size.
            let shared = MacSymbol(name: "gauge.with.needle", style: MacSymbol.Style(pointSize: 23, weight: .heavy))
            var sizes = [String](repeating: "", count: 16)
            sizes.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: 16) { i in
                    let size = Images.size(atPath: shared.withDensity(Double(i % 4 + 1)).path)
                    buffer[i] = size.map { "\($0.width)x\($0.height)" } ?? "nil"
                }
            }
            t.equal(Set(sizes).count, 1, "\(Set(sizes))")
            t.check(!sizes.contains("nil"))
        }

        t.suite("App: Mac look: symbols in Button, Bar and the background") {
            guard let (skin, host) = try loadSkin(t, """
            [Rainmeter]
            Background=sf:square.fill
            BackgroundMode=3
            SkinWidth=100
            SkinHeight=70
            ImageTint=0,128,0
            [Button]
            Meter=Button
            ButtonImage=sf:power.circle.fill
            MacSymbolSize=30
            ImageTint=255,0,0
            [Bar]
            Meter=Bar
            MeasureName=Half
            BarImage=sf:rectangle.fill
            BarOrientation=Horizontal
            MacSymbolSize=30
            ImageTint=0,0,255
            Y=40
            [Half]
            Measure=Calc
            Formula=0.5
            MaxValue=1
            """, label: "symbol-meters") else { return }
            withExtendedLifetime(host) {
                guard let button = skin.meter(named: "Button") as? ButtonMeter,
                      let bar = skin.meter(named: "Bar") as? BarMeter else { return t.check(false, "meters") }
                t.check(button.frame.width > 25 && button.frame.width < 45, "one frame: \(button.frame)")
                guard let normal = draw(skin, scale: 2) else { return t.check(false, "draws") }
                func buttonPixel(_ rep: NSBitmapImageRep) -> (r: Int, g: Int, b: Int, a: Int)? {
                    // Just inside the disc's left edge (the power sign is in the middle).
                    pixels(rep, in: CGRect(x: Int(button.frame.width * 2 * 0.15), y: Int(button.frame.height), width: 1, height: 1)).first
                }
                let before = buttonPixel(normal)
                t.check((before?.r ?? 0) > 240 && (before?.g ?? 255) < 30 && (before?.a ?? 0) > 250,
                        "the button is red: \(String(describing: before))")
                // The background symbol stretched to the skin (mode 3): green far from the top-left corner.
                let corner = pixels(normal, in: CGRect(x: 160, y: 90, width: 1, height: 1)).first
                t.check((corner?.g ?? 0) > 100 && (corner?.r ?? 255) < 30, "background: \(String(describing: corner))")
                // The bar reveals the left half of its symbol.
                let barY = Int((bar.frame.y + bar.frame.height / 2) * 2)
                let left = pixels(normal, in: CGRect(x: Int((bar.frame.x + bar.frame.width * 0.3) * 2), y: barY, width: 1,
                                                     height: 1)).first
                let right = pixels(normal, in: CGRect(x: Int((bar.frame.x + bar.frame.width * 0.7) * 2), y: barY, width: 1,
                                                      height: 1)).first
                t.check((left?.b ?? 0) > 200, "revealed: \(String(describing: left))")
                t.check((right?.b ?? 255) < 60, "not revealed: \(String(describing: right))")
                // Pressed: the same frame at half opacity (over the green background).
                _ = button.handleMouse(.leftDown, x: button.frame.x + button.frame.width * 0.15, y: button.frame.y + button.frame.height / 2)
                t.equal(button.state, .pressed)
                guard let pressed = draw(skin, scale: 2) else { return t.check(false, "draws pressed") }
                let after = buttonPixel(pressed)
                t.check((after?.a ?? 0) > 100 && (after?.a ?? 255) < 160 && (after?.r ?? 0) > 240,
                        "half opacity: \(String(describing: after))")
            }
        }
    }

    // MARK: Appearance

    static func appearanceTests(_ t: AppTestRunner) {
        t.suite("App: Mac look: appearance values") {
            let dark = MacAppearance.values(for: NSAppearance(named: .darkAqua))
            let light = MacAppearance.values(for: NSAppearance(named: .aqua))
            t.check(dark.isDark && !light.isDark)
            t.check(dark.labelColor.r > 200 && dark.labelColor.a < 255 && dark.labelColor.a > 150, "\(dark.labelColor)")
            t.check(light.labelColor.r < 40 && light.labelColor.a > 150, "\(light.labelColor)")
            t.check(dark.secondaryLabelColor.a < dark.labelColor.a && dark.tertiaryLabelColor.a < dark.secondaryLabelColor.a)
            t.check(light.separatorColor.a < 80)
            t.check(light.accentColor.a == 255 && light.accentColor != RGBA(r: 0, g: 0, b: 0), "\(light.accentColor)")
            t.equal(MacAppearance.values(for: nil), .light)
            // What skins get from the host is what is published.
            t.equal(SkinController.environment(windowFrame: nil).appearance, MacAppearance.current.value())

            // --render: Light unless asked otherwise.
            t.equal(RenderOptions.parse(["P", "--render", "a.ini"])?.appearance, .light)
            t.equal(RenderOptions.parse(["P", "--render", "a.ini", "--dark"])?.appearance, .dark)
            t.equal(RenderOptions.parse(["P", "--render", "a.ini", "--appearance", "Dark"])?.appearance, .dark)
            t.equal(RenderOptions.parse(["P", "--render", "a.ini", "--appearance", "system"])?.appearance, .system)
            let bad = RenderOptions.parse(["P", "--render", "a.ini", "--appearance", "sepia"])
            t.equal(bad?.appearance, .light)
            t.equal(bad?.warnings.count, 1)
            t.equal(RenderOptions.parse(["P", "--render", "a.ini", "--appearance"])?.warnings.count, 1)
            t.equal(CommandLineTools.validate(["P", "--render", "a.ini", "--appearance", "dark"]), .mode)

            // The sample skin, rendered light and dark: its panel follows the appearance (the theme @Include).
            guard let testSkins = Paths.repositoryFolder("TestSkins") else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            let saved = NSApp.appearance
            t.atSuiteEnd {
                NSApp.appearance = saved
                MacAppearance.current.refresh()
                DesktopInputs.appearance.refresh()
            }
            let out = t.temporaryDirectory("look-render")
            var panel: [String: Double] = [:]
            for mode in ["light", "dark"] {
                let png = out.appendingPathComponent("\(mode).png")
                let status = RenderCommand.run(["Deskset", "--render", testSkins.appendingPathComponent("Mac/Look/Look.ini").path,
                                                "--out", png.path, "--updates", "1", "--scale", "1", "--appearance", mode])
                t.equal(status, 0, mode)
                guard let rep = NSImage(contentsOf: png)?.representations.first as? NSBitmapImageRep,
                      let c = rep.colorAt(x: 290, y: 225)?.usingColorSpace(.deviceRGB) else {
                    t.check(false, "\(mode) render readable")
                    continue
                }
                panel[mode] = Double(c.redComponent + c.greenComponent + c.blueComponent) / 3
            }
            t.check((panel["light"] ?? 0) > 0.8 && (panel["dark"] ?? 1) < 0.25, "the panel follows the appearance: \(panel)")
        }

        t.suite("App: Mac look: skins that use appearance variables refresh when it changes") {
            guard let app = try AppSelfTest.makeApp(t), let testSkins = Paths.repositoryFolder("TestSkins") else { return }
            try FileManager.default.copyItem(at: testSkins.appendingPathComponent("Mac"),
                                             to: app.skinsDirectory.appendingPathComponent("Mac"))
            app.rescanLibrary()
            let saved = NSApp.appearance
            t.atSuiteEnd {
                NSApp.appearance = saved
                MacAppearance.current.refresh()
                DesktopInputs.appearance.refresh()
            }
            NSApp.appearance = NSAppearance(named: .aqua)
            app.observeAppearance()
            guard let look = app.activate(config: "Mac\\Look", file: nil),
                  let focus = app.activate(config: "App\\Focus", file: "Focus.ini") else {
                return t.check(false, "skins load")
            }
            let lookSkin: Skin = look.skin, focusSkin: Skin = focus.skin
            t.check(lookSkin.usesMacAppearance)
            t.check(!focusSkin.usesMacAppearance)
            t.equal(lookSkin.variable("MACAPPEARANCE"), "Light")
            t.equal(lookSkin.variable("Panel"), "246,246,248,240", "the light theme include")

            // Nothing changed: nothing happens.
            app.appearanceChanged()
            AppSelfTest.spin(timeout: 0.3) { false }
            t.check(app.controller(for: "Mac\\Look")?.skin === lookSkin, "no change, no refresh")

            // Dark Mode, as macOS switches it (the app's effective appearance changes; the app observes it).
            NSApp.appearance = NSAppearance(named: .darkAqua)
            let refreshed = AppSelfTest.spin(timeout: 5) { app.controller(for: "Mac\\Look")?.skin !== lookSkin }
            t.check(refreshed, "the skin that uses the variables was refreshed")
            let darkSkin = app.controller(for: "Mac\\Look")?.skin
            t.equal(darkSkin?.variable("MACAPPEARANCE"), "Dark")
            t.equal(darkSkin?.variable("MACDARKMODE"), "1")
            t.equal(darkSkin?.variable("Panel"), "30,30,32,235", "the dark theme include")
            t.check(app.controller(for: "App\\Focus")?.skin === focusSkin, "a skin without them is left alone")
            t.equal(MacAppearance.current.lastPublished?.isDark, true, "published for skins on other threads")
            t.equal(DesktopInputs.appearance.lastPublished??.bestMatch(from: [.darkAqua, .aqua]), .darkAqua,
                    "SysColor sees it too")

            // Back to light: refreshed again.
            NSApp.appearance = NSAppearance(named: .aqua)
            t.check(AppSelfTest.spin(timeout: 5) { app.controller(for: "Mac\\Look")?.skin.variable("MACAPPEARANCE") == "Light" },
                    "and back")
            app.stopAllForTermination()
        }
    }
}

private extension NSBitmapImageRep {
    /// A context over this bitmap at 2 device pixels per point (only its transform is used).
    func cgContextForTest() -> CGContext {
        let ctx = NSGraphicsContext(bitmapImageRep: self)!.cgContext
        ctx.scaleBy(x: 2, y: 2)
        return ctx
    }
}
