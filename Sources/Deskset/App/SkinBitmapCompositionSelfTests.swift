import AppKit
import DesksetCore
import DesksetDraw

enum SkinBitmapCompositionSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: bitmap composition: cropped source order preserves origin scale profile and real ink") {
            let space = CGColorSpace(name: CGColorSpace.displayP3) ?? SkinFrameProducer.sRGB
            let before = SkinRect(x: -3, y: -2, width: 4, height: 2)
            let region = GlassRegion(id: "card", rect: SkinRect(x: 3, y: 2, width: 4, height: 3))
            let initial = capture(background: [.fill(before, Paint(color: RGBA(r: 255, g: 0, b: 0)))],
                regions: [region], size: CGSize(width: 16, height: 12), origin: SkinPoint(x: -4, y: -3), scale: 2)
            // The recipe deliberately paints outside the element's declared box. Cropping that box would lose ink.
            let value = replacing(initial) { scene in
                scene.elements[0].items = [.fill(SkinRect(x: 8, y: 6, width: 2, height: 1),
                                                Paint(color: RGBA(r: 0, g: 0, b: 255)))]
            }
            let result = try SkinBitmapComposer.make(value, scale: 2, space: space, systemGlass: true)
            t.check(result.isValid(for: space)); t.equal(result.items.count, 3)
            t.equal(result.size, CGSize(width: 16, height: 12)); t.equal(result.scale, 2)
            guard case .pixels(let back) = result.items[0], case .glass(let glass) = result.items[1],
                  case .pixels(let front) = result.items[2] else { return t.check(false, "pixels / glass / pixels") }
            t.equal(back.frame(at: 2), CGRect(x: 1, y: 1, width: 4, height: 2))
            t.equal(glass.rect, SkinRect(x: 7, y: 5, width: 4, height: 3))
            t.check(front.pixelRect.maxX >= 28 && front.pixelRect.maxY >= 20, "ink outside the element frame survives")
            t.equal(back.image.width, 8); t.equal(back.image.height, 4)
            t.check(back.image.colorSpace.map { CFEqual($0, space) } == true)
            for y in 0..<back.image.height {
                for x in 0..<back.image.width {
                    let pixel = bgra(back.image, x: x, y: y)
                    t.check(pixel.map { Int($0[2]) > Int($0[0]) + Int($0[1]) && $0[2] > 200 && $0[3] == 255 } == true,
                            "every copied back pixel is opaque red in the destination profile")
                }
            }
            func frontPixel(_ x: Int, _ y: Int) -> [UInt8]? {
                bgra(front.image, x: x - front.pixelRect.minX, y: y - front.pixelRect.minY)
            }
            let blue = frontPixel(25, 19)
            t.check(blue.map { Int($0[0]) > Int($0[1]) + Int($0[2]) && $0[0] > 200 && $0[3] == 255 } == true,
                    "the bottom-right overhanging recipe is blue at its world-to-device position")
            t.equal(frontPixel(27, 11)?.last, 0, "the upper-right gap stays transparent; rows are not inverted")
            t.equal(frontPixel(15, 11)?.last, 1, "only the native glass hit area occupies the upper-left")
            for item in result.items {
                guard case .pixels(let slice) = item, let data = slice.image.dataProvider?.data else { continue }
                t.equal(CFDataGetLength(data), slice.image.bytesPerRow * slice.image.height,
                        "cropped storage does not retain a full-viewport snapshot")
            }
            t.check(result.bitmapBytes < result.pixelWidth * result.pixelHeight * 4)
            let retained = back.image.dataProvider?.data.map { $0 as Data }
            _ = try SkinBitmapComposer.make(capture(regions: [region]), scale: 1, space: space, systemGlass: true)
            t.equal(back.image.dataProvider?.data.map { $0 as Data }, retained, "later scratch work cannot overwrite a delivery")
        }

        t.suite("App: bitmap composition: text raster overhang is retained without an ideal geometry crop") {
            var style = TextStyle()
            style.fontSize = 14; style.antiAlias = true; style.accurateText = true; style.effect = .border
            style.color = RGBA(r: 255, g: 255, b: 255)
            let frame = SkinRect(x: 3, y: 3, width: 1, height: 1)
            let text = TextDraw(text: "Wide", style: style, frame: frame, contentFrame: frame, anchor: SkinPoint(x: 3, y: 3))
            let region = GlassRegion(id: "glass", rect: SkinRect(x: 80, y: 25, width: 4, height: 4))
            let input = capture(background: [.text(text)], regions: [region], size: CGSize(width: 96, height: 40))
            let result = try SkinBitmapComposer.make(input, scale: 1, space: SkinFrameProducer.sRGB, systemGlass: true)
            guard case .pixels(let pixels)? = result.items.first else { return t.check(false, "native text paints") }
            t.check(pixels.pixelRect.width > 1 && pixels.pixelRect.height > 1, "unclipped glyphs and border extend beyond layout")
        }

        t.suite("App: bitmap composition: many ordinary elements share a segment and no INI glass limit truncates") {
            let paint = DrawItem.fill(SkinRect(x: 1, y: 1, width: 1, height: 1), Paint(color: RGBA(r: 255, g: 0, b: 0)))
            let region = GlassRegion(id: "glass", rect: SkinRect(x: 8, y: 8, width: 1, height: 1))
            let initial = capture(regions: [region])
            let ordinary = (0..<5000).map { index in
                SceneElement(id: ElementID(name: "item", index: index), kind: .shape, frame: SkinRect(width: 1, height: 1),
                    anchor: SkinPoint(), visibility: .visible, container: nil, isContainer: false, items: [paint],
                    glass: nil, imageDependencies: [])
            }
            let input = replacing(initial) { $0.elements = ordinary + $0.elements }
            let many = try SkinBitmapComposer.make(input, scale: 1, space: SkinFrameProducer.sRGB, systemGlass: true)
            t.equal(many.items.count, 3, "5000 elements use one preceding cropped segment")
            t.equal(many.bitmapBytes, 8, "two one-pixel cropped images")
            let regions = (0..<65).map { GlassRegion(id: "glass-\($0)", rect: SkinRect(x: Double($0 * 2), width: 1, height: 1)) }
            let islands = try SkinBitmapComposer.make(capture(regions: regions, size: CGSize(width: 130, height: 2)),
                scale: 1, space: SkinFrameProducer.sRGB, systemGlass: false)
            t.equal(islands.items.filter { if case .glass = $0 { return true }; return false }.count, 65)
        }

        t.suite("App: bitmap composition: budget is checked before scratch and independent crop allocations") {
            let input = capture(regions: [GlassRegion(id: "a", rect: SkinRect(width: 4, height: 4))],
                                size: CGSize(width: 8, height: 6))
            let space = SkinFrameProducer.sRGB
            let result = try SkinBitmapComposer.make(input, scale: 1, space: space, systemGlass: true)
            let exact = result.scratchBytes + result.bitmapBytes
            let fits = try SkinBitmapComposer.make(input, scale: 1, space: space, systemGlass: true,
                                                  maximumBitmapBytes: exact)
            t.equal(fits.maximumBitmapBytes, exact); t.check(fits.isValid(for: space))
            expect(t, .bitmapBudgetExceeded) {
                try SkinBitmapComposer.make(input, scale: 1, space: space, systemGlass: true, maximumBitmapBytes: exact - 1)
            }
            expect(t, .bitmapBudgetExceeded) {
                try SkinBitmapComposer.make(input, scale: 1, space: space, systemGlass: true,
                                            maximumBitmapBytes: result.scratchBytes - 1)
            }
            expect(t, .bitmapBudgetExceeded) {
                try SkinBitmapComposer.make(input, scale: 1, space: space, systemGlass: true, maximumBitmapBytes: Int.min)
            }
            let huge = replacing(input, size: CGSize(width: 16384, height: 16384))
            expect(t, .bitmapBudgetExceeded) { try SkinBitmapComposer.make(huge, scale: 1, space: space, systemGlass: true) }
            let overflowing = replacing(input, size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1))
            expect(t, .invalidDestination) { try SkinBitmapComposer.make(overflowing, scale: 2, space: space, systemGlass: true) }
        }

        t.suite("App: bitmap composition: fallback islands reject earlier pixels and overlapping glass") {
            let first = GlassRegion(id: "a", rect: SkinRect(x: 1, y: 1, width: 3, height: 3))
            let second = GlassRegion(id: "b", rect: SkinRect(x: 7, y: 1, width: 3, height: 3))
            let space = SkinFrameProducer.sRGB
            let islands = try SkinBitmapComposer.make(capture(regions: [first, second]), scale: 1,
                                                      space: space, systemGlass: false)
            t.check(islands.isValid(for: space))
            let earlier = capture(background: [.fill(first.rect, Paint(color: RGBA(r: 255, g: 0, b: 0)))], regions: [first])
            expect(t, .unsupportedFallbackOverlap) { try SkinBitmapComposer.make(earlier, scale: 1, space: space, systemGlass: false) }
            var overlap = second; overlap.rect.x = 2
            let input = capture(regions: [first, overlap])
            expect(t, .unsupportedFallbackOverlap) { try SkinBitmapComposer.make(input, scale: 1, space: space, systemGlass: false) }
            t.check(try SkinBitmapComposer.make(input, scale: 1, space: space, systemGlass: true).isValid(for: space))
            // A later content segment may cover the glass: the disallowed dependency is earlier content to sample.
            let foreground = replacing(capture(regions: [first])) {
                $0.elements[0].items = [.fill(first.rect, Paint(color: RGBA(r: 255, g: 0, b: 0)))]
            }
            t.check(try SkinBitmapComposer.make(foreground, scale: 1, space: space, systemGlass: false).isValid(for: space))
        }

        t.suite("App: bitmap composition: invalid payload geometry profile and unsupported nesting fail closed") {
            let region = GlassRegion(id: "a", rect: SkinRect(x: 1, y: 1, width: 3, height: 3))
            let input = capture(regions: [region]), space = SkinFrameProducer.sRGB
            let result = try SkinBitmapComposer.make(input, scale: 1, space: space, systemGlass: true)
            if let other = CGColorSpace(name: CGColorSpace.displayP3) { t.check(!result.isValid(for: other)) }
            let broken = SkinBitmapComposition(pixelWidth: result.pixelWidth, pixelHeight: result.pixelHeight,
                scale: .nan, items: result.items, systemGlass: true, scratchBytes: result.scratchBytes,
                bitmapBytes: result.bitmapBytes, maximumBitmapBytes: result.maximumBitmapBytes)
            t.check(!broken.isValid(for: space))
            let badBytes = SkinBitmapComposition(pixelWidth: result.pixelWidth, pixelHeight: result.pixelHeight,
                scale: 1, items: result.items, systemGlass: true, scratchBytes: result.scratchBytes,
                bitmapBytes: result.bitmapBytes + 1, maximumBitmapBytes: result.maximumBitmapBytes)
            t.check(!badBytes.isValid(for: space))
            let nested = replacing(input) { $0.elements[0].items = [.antialias(true, [.glass(region)])] }
            expect(t, .nestedGlass) { try SkinBitmapComposer.make(nested, scale: 1, space: space, systemGlass: true) }
            expect(t, .qualificationFailed) {
                try SkinBitmapComposer.make(input, scale: 1, space: space, systemGlass: true, beforeDrawing: { _ in false })
            }
        }

        t.suite("App: bitmap composition: Main reuses glass interleaves siblings and releases every view") {
            let region = GlassRegion(id: "a", rect: SkinRect(x: 7, y: 1, width: 3, height: 3))
            let input = capture(background: [.fill(SkinRect(x: 1, y: 1, width: 2, height: 2),
                                                      Paint(color: RGBA(r: 255, g: 0, b: 0)))], regions: [region])
            let frame = try SkinBitmapComposer.make(input, scale: 1, space: SkinFrameProducer.sRGB, systemGlass: false)
            let view = SkinNativeCompositionView(systemGlass: false)
            t.check(view.isHidden && view.shownPieces.isEmpty && view.shownPixels.isEmpty)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            view.apply(frame)
            CATransaction.commit()
            t.equal(view.subviews.count, 3); t.equal(view.shownPixels.count, 2)
            guard let piece = view.shownPieces.first else { return t.check(false, "real fallback glass") }
            t.check(view.subviews[1] === piece.frameView)
            t.check((piece.glass as? NSVisualEffectView)?.blendingMode == .behindWindow)
            t.check(view.hitTest(CGPoint(x: 8, y: 2)) == nil, "the Desk event/AX view receives input")
            let moved = replacing(input) { $0.elements[0].glass?.rect.x = 9 }
            let next = try SkinBitmapComposer.make(moved, scale: 1, space: SkinFrameProducer.sRGB, systemGlass: false)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            view.apply(next)
            CATransaction.commit()
            t.check(view.shownPieces.first === piece); t.equal(piece.frameView.frame.minX, 9)
            let layers = view.shownPixels
            CATransaction.begin(); CATransaction.setDisableActions(true)
            view.clear()
            CATransaction.commit()
            t.check(view.isHidden && view.subviews.isEmpty && view.shownPieces.isEmpty && view.shownPixels.isEmpty)
            t.check(layers.allSatisfy { $0.contents == nil }, "held inspection layers retain no cleared images")
        }
    }

    private static func capture(background: [DrawItem] = [], regions: [GlassRegion],
                                size: CGSize = CGSize(width: 16, height: 12), origin: SkinPoint = SkinPoint(),
                                scale: CGFloat = 1) -> SkinBitmapDrawing.Capture {
        let elements = regions.enumerated().map { index, region in
            SceneElement(id: ElementID(name: region.id, index: index), kind: .shape, frame: region.rect,
                anchor: SkinPoint(x: region.rect.x, y: region.rect.y), visibility: .visible, container: nil,
                isContainer: false, items: [], glass: region, imageDependencies: [], backing: .native(.glass))
        }
        let scene = WidgetScene(generation: 1, size: SkinSize(width: size.width, height: size.height),
            background: background, backgroundImageDependencies: [], glass: [], elements: elements, hitMap: SkinHitMap(),
            environment: EnvironmentStamp(scale: Double(scale), fontGeneration: 0,
                appearance: AppearanceStamp(value: .light, name: NSAppearance.Name.aqua.rawValue), imageGeneration: 0))
        return SkinBitmapDrawing.Capture(scene: scene, context: SkinRenderContext(), cycle: 1, size: size,
                                         source: "Bitmap composition test", origin: origin)
    }

    private static func expect(_ t: AppTestRunner, _ failure: SkinBitmapComposer.Failure,
                               _ operation: () throws -> SkinBitmapComposition) {
        do { _ = try operation(); t.check(false, "expected \(failure)") }
        catch let actual as SkinBitmapComposer.Failure { t.equal(actual, failure) }
        catch { t.check(false, "unexpected error: \(error)") }
    }

    /// Captures are immutable production values; fixtures replace a value after mutating a separate scene copy.
    private static func replacing(_ input: SkinBitmapDrawing.Capture, size: CGSize? = nil,
                                  scene change: (inout WidgetScene) -> Void = { _ in }) -> SkinBitmapDrawing.Capture {
        var scene = input.scene
        change(&scene)
        return SkinBitmapDrawing.Capture(scene: scene, context: input.context, cycle: input.cycle,
            size: size ?? input.size, source: input.source, origin: input.origin)
    }

    private static func bgra(_ image: CGImage, x: Int, y: Int) -> [UInt8]? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 4 <= CFDataGetLength(data) else { return nil }
        return withExtendedLifetime(data) { Array(UnsafeBufferPointer(start: bytes.advanced(by: offset), count: 4)) }
    }
}
