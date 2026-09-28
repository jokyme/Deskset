// Question 6: base tiles that all show one image through contentsRect (nearest-neighbour filtering).
//
//   q6 --variant none|single|shared-cgimage|shared-surface|crops|copies [--window-cs default|srgb]
//        memory: this process's phys_footprint and WindowServer's footprint when a window with the tiles opens
//        (a 1600 × 1600 px base image, 9.8 MB, made fresh in each cycle; the tiles are the window minus 20 group
//        boxes; "none" is the same window without content, "copies" gives 8 tiles a copy of the image each;
//        --noise: random pixels, so the memory compressor cannot hide a copy under memory pressure)
//   q6 --readback
//        are the tiles' pixels exactly the image's? Offscreen through CARenderer (sRGB, no display color matching)
//        and on screen (tiles vs one layer showing the whole image, same window)
import AppKit
import IOSurface
import Metal
import QuartzCore

/// 20 group boxes spread over a `w` × `h` pixel window (deterministic).
func sampleHoles(_ w: Int, _ h: Int) -> [PixelRect] {
    var holes: [PixelRect] = []
    for i in 0..<20 {
        let x = (i * 397) % max(1, w - 220) + 7
        let y = (i * 263) % max(1, h - 90) + 5
        let hole = PixelRect(x0: x, y0: y, x1: x + 60 + (i * 37) % 150, y1: y + 20 + (i * 13) % 60)
        if !holes.contains(where: { $0.intersects(hole) }) { holes.append(hole) }
    }
    return holes
}

/// A base image with detail everywhere (a gradient panel with noise-like stripes), sRGB 8-bit premultiplied.
/// `noise`: random opaque pixels instead, which the memory compressor cannot shrink.
func q6BaseImage(_ w: Int, _ h: Int, noise: Bool = false) -> CGImage {
    if noise {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<(w * h) {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            bytes[i * 4] = UInt8(truncatingIfNeeded: x)
            bytes[i * 4 + 1] = UInt8(truncatingIfNeeded: x >> 8)
            bytes[i * 4 + 2] = UInt8(truncatingIfNeeded: x >> 16)
        }
        return Pixels(width: w, height: h, bytes: bytes).image(space: sRGB)
    }
    let size = CGSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2)
    let ctx = bitmapContext(size, scale: 2)
    drawPanel(ctx, size: size, radius: 28, top: Theme.panelTop, bottom: Theme.panelBottom)
    for i in 0..<60 {
        ctx.setFillColor(RGBA(255, 255, 255, Double(8 + (i * 7) % 40)).cg)
        ctx.fill(CGRect(x: CGFloat(i) * 13.37, y: CGFloat((i * 29) % 700), width: 5.3, height: 90))
    }
    return ctx.makeImage()!
}

func q6Tiles(root: CALayer, image: Any, window: PixelRect, holes: [PixelRect], scale: CGFloat,
             perTile: ((PixelRect) -> Any)? = nil) -> [CALayer] {
    var layers: [CALayer] = []
    for t in tiles(window, minus: holes) {
        let l = QuietLayer()
        l.anchorPoint = .zero
        l.contentsScale = scale
        l.frame = t.points(scale)
        if let perTile {
            l.contents = perTile(t)
        } else {
            l.contents = image
            l.contentsRect = CGRect(x: CGFloat(t.x0) / CGFloat(window.width), y: CGFloat(t.y0) / CGFloat(window.height),
                                    width: CGFloat(t.width) / CGFloat(window.width),
                                    height: CGFloat(t.height) / CGFloat(window.height))
        }
        l.contentsGravity = .resize
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        root.addSublayer(l)
        layers.append(l)
    }
    return layers
}

func imageSurface(_ image: CGImage) -> IOSurface {
    let pool = SurfacePool(width: image.width, height: image.height, space: sRGB, halfFloat: false)
    let (s, ctx) = pool.next()!
    s.lock(options: [], seed: nil)
    ctx.setBlendMode(.copy)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.flush()
    s.unlock(options: [], seed: nil)
    return s
}

func q6SharedBase() -> JSON {
    if flag("--readback") { return q6Readback() }
    let variant = option("--variant") ?? "shared-cgimage"
    let space = choice("--window-cs", WindowSpace.default)
    let noise = flag("--noise")
    let W = 1600, H = 1600
    let scale: CGFloat = 2
    let window = PixelRect(x0: 0, y0: 0, x1: W, y1: H)
    let holes = sampleHoles(W, H)
    let mb = 1024.0 * 1024.0
    var j: JSON = ["variant": variant, "windowColorSpace": space.rawValue, "imagePixels": "\(W)x\(H)", "noise": noise,
                   "imageMB": r(Double(W * H * 4) / mb, 2),
                   "holes": holes.count, "tiles": tiles(window, minus: holes).count]

    func openWindow() -> (NSPanel, CALayer) {
        let size = CGSize(width: CGFloat(W) / scale, height: CGFloat(H) / scale)
        let visible = NSScreen.main?.visibleFrame ?? .zero
        // Bottom right (the top left of the screen is the owner's).
        let panel = makePanel(NSRect(x: visible.maxX - 20 - size.width, y: visible.minY + 20,
                                     width: size.width, height: size.height))
        if let cs = nsColorSpace(space, screen: panel.screen) { panel.colorSpace = cs }
        let host = ContentHostView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        panel.contentView = host
        let root = QuietLayer()
        root.anchorPoint = .zero
        root.bounds = CGRect(origin: .zero, size: size)
        host.layer?.addSublayer(root)
        CATransaction.flush()
        return (panel, root)
    }
    /// Shows the variant; returns what must stay alive while the window is open.
    func populate(_ root: CALayer, _ image: CGImage) -> [Any] {
        switch variant {
        case "none":
            return []
        case "single":
            let l = QuietLayer()
            l.anchorPoint = .zero
            l.contentsScale = scale
            l.frame = root.bounds
            l.contents = image
            root.addSublayer(l)
            return []
        case "shared-surface":
            let surface = imageSurface(image)
            _ = q6Tiles(root: root, image: surface, window: window, holes: holes, scale: scale)
            return [surface]
        case "crops":
            _ = q6Tiles(root: root, image: image, window: window, holes: holes, scale: scale) { image.cropping(to: $0.cg)! }
            return []
        case "copies":
            // Every tile its own copy of the whole image (what "not shared" would cost), 8 tiles only.
            let few = Array(tiles(window, minus: holes).prefix(8))
            for t in few {
                // A new buffer each (Pixels.image copies the bytes).
                let copy = Pixels.of(image).image(space: sRGB)
                let l = QuietLayer()
                l.anchorPoint = .zero
                l.contentsScale = scale
                l.frame = t.points(scale)
                l.contents = copy
                l.contentsRect = CGRect(x: CGFloat(t.x0) / CGFloat(W), y: CGFloat(t.y0) / CGFloat(H),
                                        width: CGFloat(t.width) / CGFloat(W), height: CGFloat(t.height) / CGFloat(H))
                l.magnificationFilter = .nearest
                l.minificationFilter = .nearest
                root.addSublayer(l)
            }
            j["tiles"] = few.count
            return []
        default:
            _ = q6Tiles(root: root, image: image, window: window, holes: holes, scale: scale)
            return []
        }
    }
    // Warm-up with a small window of the same kind.
    autoreleasepool {
        let (p, root) = openWindow()
        let l = QuietLayer()
        l.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        l.contents = q6BaseImage(20, 20)
        root.addSublayer(l)
        p.orderFrontRegardless()
        pump(0.5)
        p.orderOut(nil)
        p.close()
    }
    pump(0.5)
    // Cycles: a fresh image, the window with the variant, then everything released (in autorelease pools: the
    // experiment runs inside one run-loop callout, whose pool would otherwise keep the closed window alive, and
    // WindowServer with it). WindowServer's estimate is the step when the window opens; close steps are recorded.
    var footprints: [Double] = [], afterClose: [Double] = [], opens: [Double] = [], closes: [Double] = []
    for cycle in 0..<3 {
        let f0 = physFootprint()
        let a = windowServerMemory().mem
        var panel: NSPanel?
        autoreleasepool {
            let image = q6BaseImage(W, H, noise: noise)
            let (p, root) = openWindow()
            let keep = populate(root, image)
            CATransaction.flush()
            p.orderFrontRegardless()
            pump(2)
            if cycle == 0 {
                j["backingStores"] = backingSummary(root)
                j["layerBitmapMB"] = r(Double(nominalBitmapBytes(root)) / mb, 2)
                j["memoryPressure"] = memoryPressure()
            }
            _ = keep
            panel = p
        }
        let f1 = physFootprint()
        let b = windowServerMemory().mem
        autoreleasepool {
            panel?.orderOut(nil)
            panel?.close()
            panel?.contentView = nil
            panel = nil
        }
        pump(1.5)
        let f2 = physFootprint()
        let c = windowServerMemory().mem
        footprints.append((f1 - f0) / mb)
        afterClose.append((f2 - f0) / mb)
        if let a, let b, let c {
            opens.append((b - a) / mb)
            closes.append((c - b) / mb)
        }
    }
    j["footprintIncreaseEachCycleMB"] = footprints.map { r($0, 2) }
    j["footprintIncreaseMedianMB"] = r(median(footprints), 2)
    j["footprintAfterCloseEachCycleMB"] = afterClose.map { r($0, 2) }
    j["windowServerOpenStepsMB"] = opens.map { r($0, 0) }
    j["windowServerCloseStepsMB"] = closes.map { r($0, 0) }
    if !opens.isEmpty { j["windowServerIncreaseMedianMB"] = r(median(opens), 1) }
    return j
}

// MARK: Read-back

/// Renders `layer` (a tree not in any window) offscreen with CARenderer into an sRGB BGRA8 texture of `w` × `h`
/// pixels, top row first. nil without a Metal device.
func renderOffscreen(_ layer: CALayer, width w: Int, height h: Int) -> Pixels? {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: desc) else { return nil }
    let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: sRGB,
                                                              kCARendererMetalCommandQueue: queue])
    renderer.layer = layer
    // The tree must be committed after it is attached to the renderer, or the renderer draws nothing.
    CATransaction.flush()
    renderer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
    renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
    renderer.addUpdate(renderer.bounds)
    renderer.render()
    renderer.endFrame()
    // Wait for the queue: an empty command buffer after the render.
    let done = queue.makeCommandBuffer()
    done?.commit()
    done?.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    // The texture's rows are bottom-up (checked with an image whose halves differ): flip them.
    var flipped = [UInt8](repeating: 0, count: bytes.count)
    for y in 0..<h {
        flipped.replaceSubrange((h - 1 - y) * w * 4..<(h - y) * w * 4, with: bytes[y * w * 4..<(y + 1) * w * 4])
    }
    return Pixels(width: w, height: h, bytes: flipped)
}

func q6Readback() -> JSON {
    guard canCapture else { return ["error": "screen capture is not allowed for this process"] }
    let W = 800, H = 600
    let scale: CGFloat = 2
    let window = PixelRect(x0: 0, y0: 0, x1: W, y1: H)
    let holes = sampleHoles(W, H)
    let image = q6BaseImage(W, H)
    let original = Pixels.of(image)
    func covered(_ x: Int, _ y: Int) -> Bool { !holes.contains { $0.contains(x: x, y: y) } }
    var j: JSON = ["imagePixels": "\(W)x\(H)", "tiles": tiles(window, minus: holes).count, "holes": holes.count]

    // Offscreen: a tree with a 2× transform so each tile pixel is one texture pixel.
    func offscreenTree(_ fill: (CALayer) -> Void) -> CALayer {
        let top = CALayer()
        top.anchorPoint = .zero
        top.bounds = CGRect(x: 0, y: 0, width: W, height: H)
        top.isGeometryFlipped = true
        let root = CALayer()
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: CGFloat(W) / scale, height: CGFloat(H) / scale)
        root.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        top.addSublayer(root)
        fill(root)
        return top
    }
    var offscreen: JSON = ["metalDevice": MTLCreateSystemDefaultDevice()?.name ?? "none"]
    for (name, contents) in [("cgimage", image as Any), ("iosurface", imageSurface(image) as Any)] {
        let tree = offscreenTree { root in
            _ = q6Tiles(root: root, image: contents, window: window, holes: holes, scale: scale)
        }
        if let p = renderOffscreen(tree, width: W, height: H) {
            offscreen["tiles(\(name)) vs image"] = compare(p, original, include: covered).json
            offscreen["holesTransparent(\(name))"] = compare(p, Pixels(width: W, height: H,
                bytes: [UInt8](repeating: 0, count: W * H * 4))) { !covered($0, $1) }.differing == 0
        }
    }
    let single = offscreenTree { root in
        let l = QuietLayer()
        l.anchorPoint = .zero
        l.contentsScale = scale
        l.frame = root.bounds
        l.contents = image
        root.addSublayer(l)
    }
    if let p = renderOffscreen(single, width: W, height: H) {
        offscreen["one layer vs image"] = compare(p, original).json
    }
    j["offscreenCARenderer"] = offscreen

    // On screen: the tiles and one layer with the whole image, side by side, in both window color spaces.
    var onScreen: JSON = [:]
    for space in [WindowSpace.default, .srgb] {
        var panels: [NSPanel] = []
        var shots: [Pixels] = []
        for (i, tiled) in [true, false].enumerated() {
            let size = CGSize(width: CGFloat(W) / scale, height: CGFloat(H) / scale)
            let panel = makePanel(NSRect(origin: gridOrigin(i, size: size, columns: 2), size: size))
            if let cs = nsColorSpace(space, screen: panel.screen) { panel.colorSpace = cs }
            let host = ContentHostView(frame: NSRect(origin: .zero, size: size))
            host.wantsLayer = true
            panel.contentView = host
            let root = QuietLayer()
            root.anchorPoint = .zero
            root.bounds = CGRect(origin: .zero, size: size)
            host.layer?.addSublayer(root)
            if tiled {
                _ = q6Tiles(root: root, image: image, window: window, holes: holes, scale: scale)
            } else {
                let l = QuietLayer()
                l.anchorPoint = .zero
                l.contentsScale = scale
                l.frame = root.bounds
                l.contents = image
                root.addSublayer(l)
            }
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        pump(1.2)
        for p in panels { if let img = captureWindow(p) { shots.append(Pixels.of(img)) } }
        if shots.count == 2 {
            onScreen["tiles vs one layer, window \(space.rawValue)"] = compare(shots[0], shots[1], include: covered).json
            if let screenSpace = panels[0].screen?.colorSpace?.cgColorSpace {
                onScreen["tiles vs image converted by CG, window \(space.rawValue)"] =
                    compare(shots[0], Pixels.drawn(image, in: screenSpace), include: covered).json
            }
        }
        for p in panels { p.orderOut(nil); p.close() }
    }
    j["onScreen"] = onScreen
    return j
}
