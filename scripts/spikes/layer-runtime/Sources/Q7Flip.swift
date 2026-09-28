// Question 7: ContentHost (a layer-backed view, isFlipped = true, wantsUpdateLayer) with the runtime's own
// contentRoot under it. Content that is not symmetric top to bottom is placed from the skin thread; the window is
// resized several times (top-left corner fixed, as Deskset does); every time the content must be where it belongs,
// and AppKit must not have written to contentRoot. Two controls use a layer-hosting view whose root layer is the
// runtime's (the draft 1.0 design): one leaves the root's geometryFlipped alone, one sets it to true itself (the draft
// flipped the root to get a top-left origin). Every write to the runtime's root that the runtime did not make itself
// is logged with its thread.
import AppKit

/// A layer that logs every property write made outside `ownWrites` (with the thread it came from).
final class RecordingLayer: CALayer {
    private let lock = NSLock()
    private var _foreign: [String] = []
    var foreign: [String] { lock.lock(); defer { lock.unlock() }; return _foreign }

    private func note(_ key: String) {
        guard Thread.current.threadDictionary["ownWrites"] as? Bool != true else { return }
        let entry = "\(key) [\(Thread.isMainThread ? "main" : "other")]"
        lock.lock()
        _foreign.append(entry)
        lock.unlock()
    }

    override func action(forKey event: String) -> CAAction? { NSNull() }
    override var bounds: CGRect { get { super.bounds } set { super.bounds = newValue; note("bounds") } }
    override var position: CGPoint { get { super.position } set { super.position = newValue; note("position") } }
    override var frame: CGRect { get { super.frame } set { super.frame = newValue; note("frame") } }
    override var anchorPoint: CGPoint { get { super.anchorPoint } set { super.anchorPoint = newValue; note("anchorPoint") } }
    override var transform: CATransform3D { get { super.transform } set { super.transform = newValue; note("transform") } }
    override var sublayerTransform: CATransform3D {
        get { super.sublayerTransform } set { super.sublayerTransform = newValue; note("sublayerTransform") }
    }
    override var isGeometryFlipped: Bool {
        get { super.isGeometryFlipped } set { super.isGeometryFlipped = newValue; note("geometryFlipped") }
    }
    override var contentsScale: CGFloat {
        get { super.contentsScale } set { super.contentsScale = newValue; note("contentsScale") }
    }
    override var isHidden: Bool { get { super.isHidden } set { super.isHidden = newValue; note("hidden") } }
    override var zPosition: CGFloat { get { super.zPosition } set { super.zPosition = newValue; note("zPosition") } }
    override var opacity: Float { get { super.opacity } set { super.opacity = newValue; note("opacity") } }
    override var masksToBounds: Bool {
        get { super.masksToBounds } set { super.masksToBounds = newValue; note("masksToBounds") }
    }
    override var mask: CALayer? { get { super.mask } set { super.mask = newValue; note("mask") } }
    override var sublayers: [CALayer]? { get { super.sublayers } set { super.sublayers = newValue; note("sublayers") } }
    override func setNeedsLayout() { super.setNeedsLayout(); note("setNeedsLayout") }
    override func removeFromSuperlayer() { super.removeFromSuperlayer(); note("removeFromSuperlayer") }

    var snapshot: JSON {
        ["bounds": "\(bounds)", "position": "\(position)", "anchorPoint": "\(anchorPoint)",
         "geometryFlipped": isGeometryFlipped, "transformIsIdentity": CATransform3DIsIdentity(transform),
         "contentsScale": contentsScale]
    }
}

/// Runs `block` with writes to RecordingLayers counted as the runtime's own.
func ownWrites<T>(_ block: () -> T) -> T {
    Thread.current.threadDictionary["ownWrites"] = true
    defer { Thread.current.threadDictionary["ownWrites"] = false }
    return block()
}

/// A view whose root layer is set by us before wantsLayer (layer-hosting): the draft 1.0 design.
final class HostingView: NSView {
    override var isFlipped: Bool { true }
}

/// An sRGB image `w` × `h` points at 2×: top half `top`, bottom half `bottom` (so upside-down content shows).
func markerImage(_ w: CGFloat, _ h: CGFloat, top: RGBA, bottom: RGBA) -> CGImage {
    let ctx = bitmapContext(CGSize(width: w, height: h), scale: 2)
    ctx.setFillColor(top.cg)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
    ctx.setFillColor(bottom.cg)
    ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
    return ctx.makeImage()!
}

/// An sRGB color as the screen shows it (captures are in the screen's color space).
func onScreen(_ c: RGBA) -> RGBA {
    guard let space = NSScreen.main?.colorSpace?.cgColorSpace,
          let converted = c.cg.converted(to: space, intent: .defaultIntent, options: nil),
          let k = converted.components, k.count >= 3 else { return c }
    return RGBA(Double(k[0]) * 255, Double(k[1]) * 255, Double(k[2]) * 255, c.a)
}

/// Where the pixels of `color` (±24 per channel, opaque) are in a capture: their bounding box in points.
func find(_ p: Pixels, _ srgbColor: RGBA, scale: CGFloat) -> CGRect? {
    let color = onScreen(srgbColor)
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<p.height {
        for x in 0..<p.width {
            let o = (y * p.width + x) * 4
            // BGRA
            let b = Int(p.bytes[o]), g = Int(p.bytes[o + 1]), rr = Int(p.bytes[o + 2]), a = Int(p.bytes[o + 3])
            guard a > 240, abs(rr - Int(color.r)) < 24, abs(g - Int(color.g)) < 24, abs(b - Int(color.b)) < 24
            else { continue }
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale,
                  height: CGFloat(maxY - minY + 1) / scale)
}

func q7Flip() -> JSON {
    guard canCapture else { return ["error": "screen capture is not allowed for this process"] }
    let thread = RunLoopThread.make("skin")
    let red = RGBA(230, 30, 30), darkRed = RGBA(90, 0, 0), blue = RGBA(30, 60, 230), darkBlue = RGBA(0, 10, 90)
    let green = RGBA(30, 200, 60)
    let markerSize = CGSize(width: 60, height: 30)
    let topImage = markerImage(markerSize.width, markerSize.height, top: red, bottom: darkRed)
    let bottomImage = markerImage(markerSize.width, markerSize.height, top: blue, bottom: darkBlue)

    func run(hosting: Bool, ownFlip: Bool = false) -> JSON {
        var size = CGSize(width: 300, height: 200)
        let visible = NSScreen.main?.visibleFrame ?? .zero
        // Room for the largest size (520 × 420 pt) at the bottom right (the top left of the screen is the owner's).
        let topLeft = NSPoint(x: visible.maxX - 580, y: visible.minY + 480)
        let panel = makePanel(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height))
        let container = FlippedView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        panel.contentView = container
        let root = RecordingLayer()
        var host: NSView
        if hosting {
            let v = HostingView(frame: container.bounds)
            ownWrites { v.layer = root }
            v.wantsLayer = true
            if ownFlip { ownWrites { root.isGeometryFlipped = true } }
            host = v
        } else {
            let v = ContentHostView(frame: container.bounds)
            v.wantsLayer = true
            host = v
        }
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        if !hosting {
            ownWrites {
                root.anchorPoint = .zero
                root.position = .zero
                root.bounds = CGRect(origin: .zero, size: size)
                host.layer?.addSublayer(root)
            }
        }
        CATransaction.flush()
        // The groups, from the skin thread: a marker at the top left, one at the bottom right, and an E layer that
        // paints a green bar along the top of its own bounds (draw(in:) orientation).
        let topMarker = QuietLayer(), bottomMarker = QuietLayer(), painted = PaintLayer()
        var drawCTM: [Double] = []
        thread.sync { ownWrites {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (l, image) in [(topMarker, topImage), (bottomMarker, bottomImage)] {
                l.anchorPoint = .zero
                l.contentsScale = 2
                l.contents = image
                root.addSublayer(l)
            }
            topMarker.frame = CGRect(origin: CGPoint(x: 10, y: 10), size: markerSize)
            bottomMarker.frame = CGRect(x: size.width - 70, y: size.height - 40, width: markerSize.width,
                                        height: markerSize.height)
            painted.anchorPoint = .zero
            painted.contentsScale = 2
            painted.contentsFormat = .RGBA8Uint
            painted.frame = CGRect(x: 100, y: 60, width: 80, height: 40)
            painted.paint = { ctx in
                drawCTM = [Double(ctx.ctm.a), Double(ctx.ctm.d)]
                ctx.setFillColor(green.cg)
                ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 10))
            }
            root.addSublayer(painted)
            CATransaction.commit()
            CATransaction.flush()
        } }
        thread.sync {
            CATransaction.begin()
            painted.setNeedsDisplay()
            painted.displayIfNeeded()
            CATransaction.commit()
            CATransaction.flush()
        }
        panel.orderFrontRegardless()
        pump(0.6)

        func check(_ label: String) -> JSON {
            guard let img = captureWindow(panel) else { return ["error": "capture failed"] }
            let p = Pixels.of(img)
            let scale = panel.backingScaleFactor
            let t = find(p, red, scale: scale), b = find(p, blue, scale: scale), g = find(p, green, scale: scale)
            let td = find(p, darkRed, scale: scale)
            let expectTop = CGRect(x: 10, y: 10, width: markerSize.width, height: markerSize.height / 2)
            let expectBottom = CGRect(x: size.width - 70, y: size.height - 40, width: markerSize.width,
                                      height: markerSize.height / 2)
            let expectGreen = CGRect(x: 100, y: 60, width: 80, height: 10)
            let ok = t == expectTop && b == expectBottom && g == expectGreen
                && td == CGRect(x: 10, y: 25, width: markerSize.width, height: markerSize.height / 2)
            return ["step": label, "windowPoints": "\(Int(size.width))x\(Int(size.height))",
                    "captureMatchesWindow": p.width == Int(size.width * scale) && p.height == Int(size.height * scale),
                    "topMarkerRedHalf": t.map { "\($0)" } ?? "missing", "bottomMarkerBlueHalf": b.map { "\($0)" } ?? "missing",
                    "paintedGreenBar": g.map { "\($0)" } ?? "missing", "allWhereExpected": ok]
        }
        var steps: [JSON] = [check("initial")]
        var appKitWrites: [JSON] = []
        for newSize in [CGSize(width: 400, height: 300), CGSize(width: 250, height: 150), CGSize(width: 300, height: 420),
                        CGSize(width: 520, height: 180)] {
            let before = root.snapshot
            let foreignBefore = root.foreign.count
            // The main thread resizes the window, keeping the top-left corner (as Deskset does).
            panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - newSize.height, width: newSize.width,
                                  height: newSize.height), display: true)
            pump(0.3)
            let afterAppKit = root.snapshot
            let written = Array(root.foreign.dropFirst(foreignBefore))
            appKitWrites.append(["resizeTo": "\(Int(newSize.width))x\(Int(newSize.height))",
                                 "contentRootWrittenByOthers": written,
                                 "contentRootUnchanged": NSDictionary(dictionary: before).isEqual(to: afterAppKit),
                                 "contentRootAfterResize": afterAppKit])
            size = newSize
            // Then the runtime, on the skin thread, updates its own tree for the new size.
            thread.sync { ownWrites {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if !hosting { root.bounds = CGRect(origin: .zero, size: newSize) }
                bottomMarker.frame = CGRect(x: newSize.width - 70, y: newSize.height - 40, width: markerSize.width,
                                            height: markerSize.height)
                CATransaction.commit()
                CATransaction.flush()
            } }
            pump(0.4)
            steps.append(check("resized"))
        }
        let hostLayer = host.layer
        let result: JSON = ["steps": steps, "appKitWritesPerResize": appKitWrites,
                            "allStepsWhereExpected": steps.allSatisfy { $0["allWhereExpected"] as? Bool == true },
                            "foreignWritesTotal": root.foreign.count,
                            "foreignWritesFirst": Array(root.foreign.prefix(12)),
                            "hostLayerGeometryFlipped": hostLayer?.isGeometryFlipped ?? false,
                            "contentRootGeometryFlipped": root.isGeometryFlipped,
                            "drawInContextCTM(a,d)": drawCTM,
                            "hostLayerClass": hostLayer.map { NSStringFromClass(type(of: $0)) } ?? "none"]
        panel.orderOut(nil)
        panel.close()
        return result
    }
    let result: JSON = ["contentHost": run(hosting: false), "layerHostingControl": run(hosting: true),
                        "layerHostingControlRootFlippedByRuntime": run(hosting: true, ownFlip: true),
                        "screenChange": "not tested: this Mac has one screen (built-in, 2×)"]
    thread.stop()
    return result
}
