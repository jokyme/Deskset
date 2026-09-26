import AppKit
import DesksetCore

/// MacGlass in the app (SkinGlass.swift): the skin window holds the glass views the engine asks for, behind the skin's
/// drawing; the macOS 13–15 fallback; the stand-ins drawn where there is no window. Uses TestSkins/Mac/Glass.
enum GlassSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: MacGlass: glass views behind the skin's drawing") {
            guard let (app, c) = try loadGlassSkin(t) else { return }
            defer { c.stop() }
            t.check(c.window.contentView === c.contentView, "the window's content holds the glass and the skin")
            t.equal(c.glass.regions.map(\.id), ["ClockCard", "CPUCard", "TintCard"])
            t.equal(c.glass.regions, c.skin.glassRegions)
            let pieces = c.glass.shownPieces
            t.equal(pieces.map { $0.frameView.frame }, [CGRect(x: 0, y: 0, width: 272, height: 120),
                                                         CGRect(x: 0, y: 132, width: 130, height: 104),
                                                         CGRect(x: 142, y: 132, width: 130, height: 104)],
                    "the Shape's rectangle, the meters' frames")
            t.check(pieces.allSatisfy { $0.glass.frame.origin == .zero && $0.glass.frame.size == $0.frameView.frame.size })
            t.equal(c.contentView.subviews, pieces.map(\.frameView) + [c.view], "back to front, the skin's drawing last")
            t.check(c.contentView.isFlipped)
            t.check(pieces.allSatisfy { $0.frameView.hitTest(NSPoint(x: 5, y: 5)) == nil }, "the glass never takes the mouse")
            t.equal(c.contentView.hitTest(NSPoint(x: 60, y: 180)), c.view, "the skin's view does")
            if #available(macOS 26.0, *) {
                let glass = pieces.compactMap { $0.glass as? NSGlassEffectView }
                t.equal(glass.count, 3, "Liquid Glass on macOS 26")
                t.equal(glass.map(\.cornerRadius), [22, 24, 24], "the Shape's corners, MacGlassCornerRadius")
                t.equal(glass.map(\.style), [.regular, .clear, .regular])
                t.equal(glass.first?.tintColor, nil)
                if let tint = glass.last?.tintColor?.usingColorSpace(.sRGB) {
                    t.close(Double(tint.redComponent), 70 / 255, accuracy: 0.002)
                    t.close(Double(tint.blueComponent), 1, accuracy: 0.002)
                    t.close(Double(tint.alphaComponent), 1, accuracy: 0.002)
                } else {
                    t.check(false, "the tint")
                }
            }

            // The tinted card has no fill: the glass catches the click, which switches the card's style.
            let tinted = pieces.last
            t.check(c.skin.mouseEvent(.leftUp, x: 200, y: 180), "the card's action runs")
            t.equal(c.glass.regions.last?.style, .clear)
            t.check(c.glass.shownPieces.last === tinted, "the same views, changed")
            if #available(macOS 26.0, *) {
                t.equal((tinted?.glass as? NSGlassEffectView)?.style, .clear)
            }

            // Off and on again: the views go and come back in file order.
            c.skin.execute("[!SetOption CPUCard MacGlass None][!UpdateMeter CPUCard][!Redraw]", from: nil)
            t.equal(c.glass.regions.map(\.id), ["ClockCard", "TintCard"])
            t.equal(c.contentView.subviews.count, 3)
            t.equal(pieces[1].frameView.superview, nil, "removed")
            c.skin.execute("[!SetOption CPUCard MacGlass Regular][!UpdateMeter CPUCard][!Redraw]", from: nil)
            t.equal(c.glass.regions.map(\.id), ["ClockCard", "CPUCard", "TintCard"])
            t.equal(c.contentView.subviews, c.glass.shownPieces.map(\.frameView) + [c.view])

            // Glass behind the whole skin, behind the cards' glass.
            c.skin.execute("[!SetOption Rainmeter MacGlass Clear][!SetOption Rainmeter MacGlassCornerRadius 30][!Redraw]",
                           from: nil)
            t.equal(c.glass.regions.first?.id, GlassRegion.skinID)
            t.equal(c.glass.shownPieces.first?.frameView.frame, CGRect(x: 0, y: 0, width: 272, height: 236))
            t.equal(c.contentView.subviews.first, c.glass.shownPieces.first?.frameView)
            t.equal(c.contentView.subviews.last, c.view)

            // A new panel (click-through turned off again) takes the glass with it.
            let frames = c.contentView.subviews
            let panel = c.window
            c.skin.execute("[!ClickThrough 1][!ClickThrough 0]", from: nil)
            t.check(c.window !== panel, "a new panel")
            t.check(c.window.contentView === c.contentView)
            t.equal(c.contentView.subviews, frames, "the same glass")

            // The skin's drawing is nearly invisible over the glass, so the window server sends clicks there to the
            // skin; between the cards it is fully transparent (clicks go through to what is behind).
            c.skin.execute("[!SetOption Rainmeter MacGlass None][!Redraw]", from: nil)
            if let rep = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) {
                c.view.cacheDisplay(in: c.view.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / max(c.view.bounds.width, 1)
                func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
                    rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? -1
                }
                t.check(alpha(4, 190) > 0 && alpha(4, 190) < 0.02, "over the glass: \(alpha(4, 190))")
                t.equal(alpha(136, 190), 0, "between the cards")
                t.equal(alpha(1, 133), 0, "outside a rounded corner")
            } else {
                t.check(false, "the skin view draws")
            }
            withExtendedLifetime(app) {}
        }

        t.suite("App: MacGlass: macOS 13–15 fallback") {
            SkinGlassViews.forcesFallback = true
            defer { SkinGlassViews.forcesFallback = false }
            guard let (app, c) = try loadGlassSkin(t) else { return }
            defer { c.stop() }
            let pieces = c.glass.shownPieces
            let effects = pieces.compactMap { $0.glass as? NSVisualEffectView }
            t.equal(effects.count, 3, "NSVisualEffectView")
            t.check(pieces.allSatisfy { !$0.isSystemGlass })
            t.equal(effects.map(\.material), [.popover, .hudWindow, .popover], "Regular and Clear")
            t.check(effects.allSatisfy { $0.blendingMode == .behindWindow && $0.state == .active },
                    "blurs what is behind the window")
            t.check(effects.allSatisfy { $0.maskImage != nil }, "rounded")
            t.equal(effects.first?.maskImage?.capInsets.top, 22)
            t.equal(pieces.map { $0.tint?.isHidden }, [true, true, false], "tinted only where MacGlassTint is")
            if let color = pieces.last?.tint?.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB) {
                t.close(Double(color.greenComponent), 130 / 255, accuracy: 0.002)
                t.close(Double(color.alphaComponent), Double(SkinGlassViews.fallbackTintStrength), accuracy: 0.002,
                        "the glass leans toward the tint, it is not covered by it")
            } else {
                t.check(false, "the tint's color")
            }
            t.equal(pieces.last?.tint?.layer?.cornerRadius, 24)
            t.equal(pieces.last?.tint?.frame, pieces.last?.glass.bounds)
            c.skin.execute("[!SetOption CPUCard MacGlassCornerRadius 0][!UpdateMeter CPUCard][!Redraw]", from: nil)
            t.equal((c.glass.shownPieces[1].glass as? NSVisualEffectView)?.maskImage, nil, "square: no mask")
            t.check(c.glass.shownPieces[1] === pieces[1], "the same view")
            // Cut off by a container: the frame view clips.
            c.skin.execute("[!SetOption CPUCard Container ClockCard][!SetOption CPUCard Y 60][!UpdateMeter CPUCard][!Redraw]",
                           from: nil)
            if let region = c.glass.regions.first(where: { $0.id == "CPUCard" }), let clip = region.clip {
                let piece = c.glass.shownPieces[1]
                t.equal(piece.frameView.frame, clip.cgRect, "the container's frame")
                t.check(piece.frameView.layer?.masksToBounds == true, "clips")
                t.equal(piece.glass.frame.origin, CGPoint(x: region.rect.x - clip.x, y: region.rect.y - clip.y))
            } else {
                t.check(false, "the card is cut off by the clock card: \(c.glass.regions)")
            }
            withExtendedLifetime(app) {}
        }

        t.suite("App: MacGlass: stand-ins where there is no window") {
            let ini = "[Rainmeter]\nUpdate=-1\n[Pad]\nMeter=Image\nW=140\nH=90\n"
                + "[Card]\nMeter=Image\nX=10\nY=10\nW=100\nH=60\nMacGlass=Regular\nMacGlassCornerRadius=12\n"
            let (skin, host) = try MediaUITests.bareSkin(t, ini)
            skin.update()
            guard let rep = AppSelfTest.drawSkin(skin, width: 140, height: 90) else { return t.check(false, "draws") }
            func alpha(_ r: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat { r.colorAt(x: x, y: y)?.alphaComponent ?? -1 }
            t.check(alpha(rep, 60, 40) > 0.2, "a translucent body: \(alpha(rep, 60, 40))")
            t.equal(alpha(rep, 3, 3), 0, "nothing outside it")
            t.equal(alpha(rep, 10, 10), 0, "rounded")
            t.check(alpha(rep, 10, 40) > alpha(rep, 60, 40), "a hairline edge")
            // Light and dark stand-ins differ; the window draws only the hit area.
            func draw(_ glass: SkinRenderer.GlassDrawing) -> CGFloat {
                guard let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 140, pixelsHigh: 90, bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: r) else { return -1 }
                let cg = context.cgContext
                cg.translateBy(x: 0, y: 90)
                cg.scaleBy(x: 1, y: -1)
                SkinRenderer.draw(skin, in: cg, glass: glass)
                return alpha(r, 60, 40)
            }
            t.check(draw(.placeholder(dark: false)) > draw(.placeholder(dark: true)), "frostier over light backgrounds")
            t.check(draw(.window) > 0 && draw(.window) < 0.02, "the window: only a fill no one sees")
            t.equal(draw(.none), 0)
            t.check(GlassPlaceholder.isDark(RGBA(r: 20, g: 20, b: 30, a: 255)))
            t.check(!GlassPlaceholder.isDark(RGBA(r: 240, g: 240, b: 240, a: 255)))
            t.check(!GlassPlaceholder.isDark(RGBA(r: 0, g: 0, b: 0, a: 0)), "a transparent background is no dark one")
            // A layer's thumbnail shows its glass too.
            if let meter = skin.meter(named: "Card"),
               let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 140, pixelsHigh: 90, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
               let context = NSGraphicsContext(bitmapImageRep: r) {
                let cg = context.cgContext
                cg.translateBy(x: 0, y: 90)
                cg.scaleBy(x: 1, y: -1)
                SkinRenderer.drawMeter(meter, cg)
                t.check(alpha(r, 60, 40) > 0.2, "the layer's thumbnail")
            } else {
                t.check(false, "the Card layer")
            }
            withExtendedLifetime(host) {}
        }

        t.suite("App: MacGlass: layer tiles follow glass changes") {
            let ini = "[Rainmeter]\nUpdate=-1\n[Card]\nMeter=Image\nW=100\nH=60\nMacGlass=Regular\nMacGlassCornerRadius=8\n"
            let (skin, host) = try MediaUITests.bareSkin(t, ini)
            skin.update()
            guard let card = skin.meter(named: "Card") else { return t.check(false, "the layer") }
            // The layer list's tile follows the glass: !SetOption turns it Clear, tints it, then turns it off.
            let thumbnails = LayerThumbnails()
            func tile() -> NSImage? {
                thumbnails.beginPass()
                return thumbnails.thumbnail(key: "Card", meters: [card], in: skin, panel: .black, dark: true)
            }
            let regular = tile()
            let drawn = thumbnails.renderCount
            _ = tile()
            t.equal(thumbnails.renderCount, drawn, "nothing changed: the cached tile")
            skin.execute("[!SetOption Card MacGlass Clear][!UpdateMeter Card][!Redraw]", from: nil)
            let clear = tile()
            t.equal(thumbnails.renderCount, drawn + 1, "the glass changed: drawn again")
            t.check(clear !== regular)
            skin.execute("[!SetOption Card MacGlassTint 255,0,0][!UpdateMeter Card][!Redraw]", from: nil)
            _ = tile()
            t.equal(thumbnails.renderCount, drawn + 2, "the tint changed")
            skin.execute("[!SetOption Card MacGlass None][!UpdateMeter Card][!Redraw]", from: nil)
            _ = tile()
            t.equal(thumbnails.renderCount, drawn + 3, "the glass is gone")
            withExtendedLifetime(host) {}
        }

        t.suite("App: MacGlass: pictures of several layers keep the glass behind them") {
            let ini = "[Rainmeter]\nUpdate=-1\n[Label]\nMeter=Image\nW=100\nH=60\nSolidColor=0,0,0,255\n"
                + "[Card]\nMeter=Image\nW=100\nH=60\nMacGlass=Regular\nMacGlassCornerRadius=8\n"
            let (skin, host) = try MediaUITests.bareSkin(t, ini)
            skin.update()
            guard let label = skin.meter(named: "Label"), let card = skin.meter(named: "Card") else {
                return t.check(false, "the layers")
            }
            // A later glass meter over an earlier layer: its stand-in goes behind the layer, as the window's glass does.
            func center(_ draw: (CGContext) -> Void) -> NSColor? {
                guard let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 60, bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: r) else { return nil }
                let cg = context.cgContext
                cg.translateBy(x: 0, y: 60)
                cg.scaleBy(x: 1, y: -1)
                draw(cg)
                return r.colorAt(x: 50, y: 30)
            }
            let both = center { SkinRenderer.drawMeters([label, card], $0) }
            t.check((both?.redComponent ?? 1) < 0.02 && (both?.alphaComponent ?? 0) > 0.98,
                    "the black layer is not washed out by the glass drawn after it: \(String(describing: both))")
            let alone = center { SkinRenderer.drawMeters([card], $0) }
            t.check((alone?.alphaComponent ?? 0) > 0.2, "the glass alone still shows its stand-in")
            withExtendedLifetime(host) {}
        }
    }

    /// An app whose Skins folder has TestSkins/Mac, with Mac\Glass loaded (headless).
    static func loadGlassSkin(_ t: AppTestRunner) throws -> (AppController, SkinController)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        guard let mac = Paths.repositoryFolder("TestSkins")?.appendingPathComponent("Mac") else {
            print("    (skipped: TestSkins not found; run from the repository)")
            return nil
        }
        try FileManager.default.copyItem(at: mac, to: app.skinsDirectory.appendingPathComponent("Mac"))
        guard let c = app.activate(config: "Mac\\Glass", file: nil) else {
            t.check(false, "Mac\\Glass loads")
            return nil
        }
        return (app, c)
    }
}
