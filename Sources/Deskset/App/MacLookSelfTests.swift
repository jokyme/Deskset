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
        editorTests(t)
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

    private static func weightTrait(_ font: CTFont) -> Double {
        ((CTFontCopyTraits(font) as? [CFString: Any])?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
    }

    private static func widthTrait(_ font: CTFont) -> Double {
        ((CTFontCopyTraits(font) as? [CFString: Any])?[kCTFontWidthTrait] as? NSNumber)?.doubleValue ?? 0
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
            // Every weight, Medium too, in every design with italics.
            for face in ["System", "System Mono", "New York"] where Fonts.installedFamily(named: face) == nil {
                for weight in [300, 400, 500, 600, 700, 900] {
                    let upright = fontName(face, weight: weight), italic = fontName(face, weight: weight, italic: true)
                    t.close(weightTrait(italic.resolved.font), weightTrait(upright.resolved.font), accuracy: 0.01,
                            "\(face) \(weight): \(upright.name) → \(italic.name)")
                    t.check(CTFontGetSymbolicTraits(italic.resolved.font).contains(.traitItalic) && italic.resolved.slant == 0,
                            "\(face) \(weight): a true italic \(italic.name)")
                }
            }
            // A condensed width has no italic: the condensed face at its weight, slanted (not a regular-width upright).
            for weight in [400, 700] {
                let upright = Fonts.resolve(Fonts.Request(face: "System", size: 20, weight: weight, stretch: 3))
                let italic = Fonts.resolve(Fonts.Request(face: "System", size: 20, weight: weight, italic: true, stretch: 3))
                let name = CTFontCopyPostScriptName(italic.font) as String
                t.check(widthTrait(italic.font) < -0.05, "condensed \(weight) keeps its width: \(name)")
                t.close(weightTrait(italic.font), weightTrait(upright.font), accuracy: 0.01, "condensed \(weight) keeps its weight: \(name)")
                t.check(italic.slant > 0, "condensed \(weight) is slanted: \(name)")
            }
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

        t.suite("App: Mac look: palette symbols draw each layer in its color") {
            guard let (skin, host) = try loadSkin(t, """
            [Rainmeter]
            [Palette]
            ; the cloud (layer 1) blue, the sun (layer 2) yellow
            Meter=Image
            ImageName=sf:cloud.sun.fill
            MacSymbolRendering=Palette
            MacSymbolColors=0,0,255|255,204,0
            MacSymbolSize=40
            [Short]
            ; three layers, two colors: the rain takes the last one
            Meter=Image
            ImageName=sf:cloud.sun.rain.fill
            MacSymbolRendering=Palette
            MacSymbolColors=0,0,255|255,0,0
            MacSymbolSize=40
            X=60
            [Tinted]
            ; ImageTint multiplies the colors; ImageAlpha fades them
            Meter=Image
            ImageName=sf:cloud.sun.fill
            MacSymbolRendering=Palette
            MacSymbolColors=255,255,255|255,204,0
            ImageTint=0,255,0
            ImageAlpha=128
            MacSymbolSize=40
            X=120
            [Plain]
            ; a palette without colors is white, as Monochrome
            Meter=Image
            ImageName=sf:cloud.sun.fill
            MacSymbolRendering=Palette
            MacSymbolSize=40
            X=180
            [Translucent]
            ; a color's own alpha
            Meter=Image
            ImageName=sf:cloud.fill
            MacSymbolRendering=Palette
            MacSymbolColors=0,0,0,153
            MacSymbolSize=40
            X=240
            """, label: "palette") else { return }
            withExtendedLifetime(host) {
                t.check(skin.issues.isEmpty, "\(skin.issues)")
                guard let rep = draw(skin, scale: 2) else { return t.check(false, "draws") }
                func opaque(_ x: Int) -> [(r: Int, g: Int, b: Int, a: Int)] {
                    pixels(rep, in: CGRect(x: x, y: 0, width: 110, height: 100)).filter { $0.a > 250 }
                }
                let palette = opaque(0)
                t.check(palette.filter { $0.r < 10 && $0.g < 10 && $0.b > 245 }.count > 1000, "a blue cloud")
                t.check(palette.filter { $0.r > 245 && abs($0.g - 204) < 6 && $0.b < 10 }.count > 200, "a yellow sun")
                t.check(!palette.contains { $0.r > 240 && $0.g > 240 && $0.b > 240 }, "nothing white")
                let short = opaque(120)
                t.check(short.filter { $0.r > 245 && $0.g < 10 && $0.b < 10 }.count > 300, "sun and rain both red")
                let tinted = pixels(rep, in: CGRect(x: 240, y: 0, width: 110, height: 100)).filter { $0.a > 100 }
                t.check(!tinted.isEmpty && tinted.allSatisfy { $0.r < 10 && $0.b < 10 && $0.a <= 130 },
                        "tinted green and faded: \(tinted.prefix(3))")
                let plain = opaque(360)
                t.check(!plain.isEmpty && plain.allSatisfy { $0.r > 240 && $0.g > 240 && $0.b > 240 }, "white")
                let translucent = pixels(rep, in: CGRect(x: 480, y: 0, width: 110, height: 100)).filter { $0.a > 20 }
                t.check(!translucent.isEmpty && translucent.allSatisfy { $0.a <= 156 && $0.r < 10 },
                        "the color's alpha: \(translucent.map(\.a).max() ?? 0)")
            }
            // One drawing per set of colors; the same colors share it.
            let a = MacSymbol(name: "cloud.sun.fill", style: MacSymbol.Style(rendering: .palette, colors: [.black, .white]))
            let b = MacSymbol(name: "cloud.sun.fill", style: MacSymbol.Style(rendering: .palette, colors: [.white, .black]))
            t.check(a.path != b.path)
            if let ia = Images.cgImage(atPath: a.path), let ib = Images.cgImage(atPath: b.path) {
                t.check(ia !== ib, "two drawings")
                t.check(Images.cgImage(atPath: a.path) === ia, "cached")
            } else {
                t.check(false, "palette symbols render")
            }
        }

        t.suite("App: Mac look: a symbol drawn far larger than its size stays sharp") {
            // W=H=256 at the default MacSymbolSize (16) on a Retina display: some 27 pixels per point.
            guard let (skin, host) = try loadSkin(t, """
            [Rainmeter]
            [Big]
            Meter=Image
            ImageName=sf:circle.fill
            W=256
            H=256
            """, label: "big-symbol") else { return }
            withExtendedLifetime(host) {
                guard let rep = draw(skin, scale: 2), let natural = Images.size(atPath: MacSymbol(name: "circle.fill").path)
                else { return t.check(false, "draws") }
                let path = SymbolImages.drawingPath(MacSymbol(name: "circle.fill").path, options: ImageOptions(),
                                                    drawn: CGSize(width: 256, height: 256), fit: true, in: rep.cgContextForTest())
                let expected = ((2 * min(256 / natural.width, 256 / natural.height)) * 8).rounded(.up) / 8
                t.check(expected > 16, "more than the old limit: \(expected)")
                t.close(MacSymbol(path: path)?.density ?? 0, expected, accuracy: 1e-9, "rendered at the pixels it covers: \(path)")
                // Across the middle row, the edge goes from clear to opaque within a pixel or two (scaled up from a
                // smaller render, it took three or more).
                let row = pixels(rep, in: CGRect(x: 0, y: 256, width: 256, height: 1)).map(\.a)
                let ramp = row.prefix { $0 < 245 }.filter { $0 > 10 }.count
                t.check(ramp <= 2, "a sharp edge: \(row.prefix { $0 < 245 }.suffix(5))")
            }
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
            var fallback = SkinAppearance.light
            fallback.regional = MacRegional.current
            t.equal(MacAppearance.values(for: nil), fallback)
            t.equal(dark.regional, MacRegional.current, "the clock, week and temperature settings come with it")
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

        t.suite("App: Mac look: skins follow the clock, week and temperature settings") {
            guard let app = try AppSelfTest.makeApp(t), let testSkins = Paths.repositoryFolder("TestSkins") else { return }
            try FileManager.default.copyItem(at: testSkins.appendingPathComponent("Mac"),
                                             to: app.skinsDirectory.appendingPathComponent("Mac"))
            app.rescanLibrary()
            // What "the Mac's settings" are, for this suite: a 24-hour clock, weeks from Monday, °C.
            let mac = Guarded(MacRegionalSettings(clockHours: 24, firstWeekday: 1, temperatureUnit: .celsius))
            MacRegional.setSource { mac.current }
            t.atSuiteEnd {
                MacRegional.setSource(nil)
                MacAppearance.current.refresh()
            }
            app.observeAppearance()
            guard let regional = app.activate(config: "Mac\\Regional", file: nil),
                  let focus = app.activate(config: "App\\Focus", file: "Focus.ini") else {
                return t.check(false, "skins load")
            }
            let skin: Skin = regional.skin, focusSkin: Skin = focus.skin
            t.check(skin.usesMacAppearance, "a skin that uses them follows the Mac")
            t.equal([skin.variable("MACCLOCKHOURS"), skin.variable("MACFIRSTWEEKDAY"), skin.variable("MACTEMPERATUREUNIT")],
                    ["24", "1", "C"])
            t.equal(skin.variable("ClockHoursAuto"), "24", "an Auto setting built on it")
            t.equal(skin.measure(named: "MeasureWeekStart")?.stringValue, "Monday")
            t.equal(WeatherWiring.skinUnits().temperature, .celsius, "the weather plugins' Units=Auto agrees")
            t.check(WeatherWiring.liveEnvironment().uses24HourClock(), "and so do their default times")

            // Nothing changed: nothing happens.
            app.regionalSettingsChanged()
            AppSelfTest.spin(timeout: 0.3) { false }
            t.check(app.controller(for: "Mac\\Regional")?.skin === skin, "no change, no refresh")

            // macOS says the locale changed (System Settings: 12-hour time, weeks from Sunday, °F).
            mac.access { $0 = MacRegionalSettings(clockHours: 12, firstWeekday: 0, temperatureUnit: .fahrenheit) }
            NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
            let refreshed = AppSelfTest.spin(timeout: 5) { app.controller(for: "Mac\\Regional")?.skin !== skin }
            t.check(refreshed, "the skin that uses the variables was refreshed")
            let now = app.controller(for: "Mac\\Regional")?.skin
            t.equal([now?.variable("MACCLOCKHOURS"), now?.variable("MACFIRSTWEEKDAY"), now?.variable("MACTEMPERATUREUNIT")],
                    ["12", "0", "F"])
            t.equal(now?.variable("ClockHoursAuto"), "12")
            t.equal(now?.measure(named: "MeasureWeekStart")?.stringValue, "Sunday")
            t.check(now?.measure(named: "MeasureTime")?.stringValue.hasSuffix("M") == true,
                    "the time in 12-hour form: \(now?.measure(named: "MeasureTime")?.stringValue ?? "")")
            t.check(app.controller(for: "App\\Focus")?.skin === focusSkin, "a skin without them is left alone")
            t.equal(MacAppearance.current.lastPublished?.regional.clockHours, 12, "published for skins on other threads")
            t.equal(WeatherWiring.skinUnits().temperature, .fahrenheit)
            t.check(!WeatherWiring.liveEnvironment().uses24HourClock())

            // The preference keys behind them are watched as well (another process writes them).
            // A suite named by a path keeps its file in the test's own folder: a named one would leave a file in
            // ~/Library/Preferences, which the preferences daemon writes again even after it is removed.
            let suite = t.temporaryDirectory("regional-defaults").appendingPathComponent("regional").path
            guard let defaults = UserDefaults(suiteName: suite) else { return t.check(false, "a defaults suite") }
            var heard = 0
            let observer = RegionalDefaultsObserver(defaults: defaults) { heard += 1 }
            defaults.set("Fahrenheit", forKey: "AppleTemperatureUnit")
            defaults.set(true, forKey: "AppleICUForce24HourTime")
            t.check(AppSelfTest.spin(timeout: 2) { heard >= 2 }, "each change is heard: \(heard)")
            // Written by another process, as System Settings writes them.
            let writer = Process()
            writer.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            writer.arguments = ["write", suite, "AppleFirstWeekday", "-dict", "gregorian", "-int", "2"]
            try writer.run()
            writer.waitUntilExit()
            t.equal(writer.terminationStatus, 0)
            t.check(AppSelfTest.spin(timeout: 5) { heard >= 3 }, "another process's change is heard: \(heard)")
            withExtendedLifetime(observer) {}
            app.stopAllForTermination()
        }

        t.suite("App: Mac look: --render's clock, week and temperature settings") {
            let plain = RenderOptions.parse(["P", "--render", "a.ini"])
            t.equal(plain?.regional(system: MacRegionalSettings(clockHours: 12, firstWeekday: 3, temperatureUnit: .fahrenheit)),
                    .standard, "the standard ones unless asked: the same on every Mac")
            let asked = RenderOptions.parse(["P", "--render", "a.ini", "--clock-hours", "12", "--first-weekday", "1",
                                             "--temperature-unit", "f"])
            t.equal(asked?.regional(system: .standard),
                    MacRegionalSettings(clockHours: 12, firstWeekday: 1, temperatureUnit: .fahrenheit))
            t.equal(asked?.warnings, [])
            let system = RenderOptions.parse(["P", "--render", "a.ini", "--clock-hours", "system", "--first-weekday",
                                              "System", "--temperature-unit", "system"])
            let mine = MacRegionalSettings(clockHours: 12, firstWeekday: 5, temperatureUnit: .fahrenheit)
            t.equal(system?.regional(system: mine), mine, "system: the Mac's own")
            let mixed = RenderOptions.parse(["P", "--render", "a.ini", "--first-weekday", "system"])
            t.equal(mixed?.regional(system: mine), MacRegionalSettings(clockHours: 24, firstWeekday: 5, temperatureUnit: .celsius))
            let bad = RenderOptions.parse(["P", "--render", "a.ini", "--clock-hours", "13", "--first-weekday", "7",
                                           "--temperature-unit", "K"])
            t.equal(bad?.regional(system: mine), .standard, "wrong values keep the standard ones")
            t.equal(bad?.warnings.count, 3)
            t.equal(RenderOptions.parse(["P", "--render", "a.ini", "--clock-hours"])?.warnings.count, 1)
            t.equal(CommandLineTools.validate(["P", "--render", "a.ini", "--clock-hours", "12", "--first-weekday", "1",
                                               "--temperature-unit", "F"]), .mode)
            t.check(CommandLineTools.usage.contains("--temperature-unit"))
        }
    }
}

extension MacLookSelfTests {
    // MARK: Editor

    static func editorTests(_ t: AppTestRunner) {
        t.suite("App: Mac look: the editor shows a symbol as the widget draws it") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Mac\\Look") else { return }
            // The picture's thumbnail uses the layer's MacSymbolWeight and MacSymbolRendering.
            for (section, name, weight, rendering) in [("MeterWeather", "cloud.sun.fill", MacSymbol.Weight.regular, MacSymbol.Rendering.multicolor),
                                                       ("MeterMemory", "memorychip", .semibold, .monochrome),
                                                       ("MeterWiFi", "wifi", .regular, .hierarchical)] {
                let path = editor.imagePath(ctxSection: section, key: "ImageName", resolved: "sf:\(name)")
                let symbol = path.flatMap { MacSymbol(path: $0) }
                t.equal(symbol?.style.weight, weight, section)
                t.equal(symbol?.style.rendering, rendering, section)
            }
            t.equal(editor.imagePath(ctxSection: "MeterPower", key: "ButtonImage", resolved: "sf:power.circle.fill")
                .flatMap { MacSymbol(path: $0) }?.style.pointSize, 17, "MacSymbolSize too")
            editor.window?.close()
        }

        t.suite("App: Mac look: the widget page says what switching light / dark does") {
            typealias P = FriendlyWidgetPageSelfTests
            let key = "MacOnAppearanceChangeAction"
            for (written, follows) in [(false, false), (false, true), (true, false), (true, true)] {
                let choices = InspectorWindowController.whenTheWidgetChoices(key, written: written, followsAppearance: follows)
                t.check(!choices.others.isEmpty, "a choice besides the current one (\(written), \(follows))")
                for title in [choices.current] + choices.others.map(\.title) {
                    t.equal(EditorSchema.engineWord(in: title), nil, title)
                }
            }
            func row(_ editor: InspectorWindowController) -> NSPopUpButton? {
                P.openEverything(editor)
                return P.find(editor, "when-\(key)") as? NSPopUpButton
            }

            // A widget without the Mac's colors does nothing when macOS switches; it can be made to reload.
            guard let (_, plain) = try P.openScratch(t, files: ["Look/Plain/Plain.ini": "[Rainmeter]\nUpdate=1000\n\n[M]\nMeter=String\nText=Hi\n"],
                                                     config: "Look\\Plain"),
                  let plainIni = plain.skin?.fileURL else { return }
            plain.canvasSelectionChanged([])
            t.equal(row(plain)?.titleOfSelectedItem, "No action (it doesn't use Mac colors)")
            t.check(P.choose(row(plain), "Reload the widget"))
            t.check(P.section("Rainmeter", in: P.read(plainIni)).contains("\(key)=[!Refresh]\n"), P.read(plainIni))
            t.equal(plain.skin?.usesMacAppearance, true, "written, it reloads")
            t.check(row(plain) == nil, "a written action is shown as a sentence")
            plain.window?.close()

            // A widget that uses them reloads; "No action" writes the option empty, "Reload the widget" removes it again.
            guard let (_, mac) = try P.openScratch(t, files: ["Look/Mac/Mac.ini":
                "[Rainmeter]\nUpdate=1000\n\n[M]\nMeter=String\nText=Hi\nFontColor=#MACLABELCOLOR#\n"], config: "Look\\Mac"),
                  let macIni = mac.skin?.fileURL else { return }
            mac.canvasSelectionChanged([])
            t.equal(row(mac)?.titleOfSelectedItem, "Reload the widget")
            t.check(P.choose(row(mac), "No action"))
            t.check(P.section("Rainmeter", in: P.read(macIni)).contains("\(key)=\n"), P.read(macIni))
            t.equal(row(mac)?.titleOfSelectedItem, "No action")
            t.check(P.choose(row(mac), "Reload the widget"))
            t.check(!P.read(macIni).contains(key), "back to the default: \(P.read(macIni))")
            t.equal(row(mac)?.titleOfSelectedItem, "Reload the widget")
            mac.window?.close()
        }

        t.suite("App: Mac look: a Mac color follows macOS in the editor") {
            // FontColor=#MACLABELCOLOR# is the Mac's color, not a shared value of the widget: [Variables] cannot set it
            // (this widget even has a fallback of that name for Windows), so the editor never writes it there.
            typealias P = FriendlyWidgetPageSelfTests
            guard let (_, editor) = try P.openScratch(t, files: ["Look/Colors/Colors.ini": """
                [Rainmeter]
                Update=1000

                [Variables]
                MACLABELCOLOR=0,0,0,217
                Accent=255,128,0

                [StyleText]
                FontColor=#MACSECONDARYLABELCOLOR#

                [Title]
                Meter=String
                Text=Title
                FontColor=#MACLABELCOLOR#

                [Sub]
                Meter=String
                MeterStyle=StyleText
                Y=20
                Text=Sub

                [Box]
                Meter=Shape
                Y=40
                Shape=Rectangle 0,0,40,10 | Fill Color #MACACCENTCOLOR#

                [Tinted]
                Meter=String
                Y=60
                Text=Tinted
                FontColor=#Accent#
                """], config: "Look\\Colors"),
                  let skin = editor.skin, let ini = editor.skin?.fileURL else { return }
            let original = P.read(ini)
            let groups = skin.valueUsages().colorGroups()
            t.check(!groups.contains { $0.variables.contains { BuiltInVariables.isBuiltIn($0) } }, "the fallback is no theme color")
            t.check(groups.contains { $0.variables == ["Accent"] }, "a color of the widget's own is")

            editor.select(section: "Title")
            guard let control = P.find(editor, "FontColor.row") as? ColorControl, let menu = control.colorMenu else {
                return t.check(false, "the font color control")
            }
            t.equal(control.nameButton.title, "Mac text color")
            t.check(control.swatch.toolTip?.contains("follows macOS") == true, control.swatch.toolTip ?? "")
            func item(_ menu: NSMenu, _ id: String) -> NSMenuItem? { menu.items.first { $0.identifier?.rawValue == id } }
            t.equal(item(menu, "follows-mac")?.title, "Mac text color · follows macOS")
            t.equal(item(menu, "change-everywhere"), nil, "no shared value to change")
            t.equal(item(menu, "custom-color")?.title, "Use a Fixed Color…")
            t.equal(item(menu, "theme-color-MACLABELCOLOR"), nil)
            t.check(item(menu, "theme-color-Accent") != nil, "the widget's own colors can still be chosen")

            // Where a new color goes: the option itself (its look when the layer takes it from one), never [Variables].
            let resolver = ScopeResolver(skin: skin)
            t.equal(resolver.target(section: "Title", key: "FontColor", selection: ["Title"], variable: "MACLABELCOLOR").scope, .own)
            t.equal(resolver.target(section: "Sub", key: "FontColor", selection: ["Sub"], variable: "MACSECONDARYLABELCOLOR").scope,
                    .look("StyleText"))
            t.equal(resolver.target(section: "Tinted", key: "FontColor", selection: ["Tinted"], variable: "Accent").scope,
                    .sharedValue("Accent"), "a variable of the widget's own still is a shared value")
            editor.startColorEdit(ColorEdit(target: .property(section: "Title", key: "FontColor", raw: "#MACLABELCOLOR#",
                                                              variable: "MACLABELCOLOR", label: "Color", selection: ["Title"])),
                                  current: nil)
            editor.previewColorEdit(RGBA(r: 255, g: 0, b: 0, a: 255))
            t.equal((editor.skin?.meter(named: "Title") as? StringMeter)?.style.color, RGBA(r: 255, g: 0, b: 0, a: 255),
                    "previewed on the layer")
            editor.finishColorEdit()
            let written = P.read(ini)
            t.check(P.section("Title", in: written).contains("FontColor=255,0,0"), P.section("Title", in: written))
            t.equal(P.section("Variables", in: written), P.section("Variables", in: original), "[Variables] is not touched")
            // The older swatch path (the Variables page, the Shape editor) does the same.
            editor.beginColorEdit(section: "Sub", key: "FontColor", raw: "#MACSECONDARYLABELCOLOR#", variable: "MACSECONDARYLABELCOLOR")
            t.check(editor.colorTarget != nil && editor.colorTarget?.variable == nil, "the option, not the built-in")
            editor.colorTarget = nil

            // A Shape's fill: the same.
            editor.select(section: "Box")
            let shape = editor.shapePaintMenu(meter: "Box", key: "Shape", stroke: false, swatch: nil)
            t.check(item(shape, "follows-mac")?.title.hasSuffix("follows macOS") == true)
            t.equal(item(shape, "change-everywhere"), nil)
            t.equal(item(shape, "custom-color")?.title, "Use a Fixed Color…")
            editor.window?.close()
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
