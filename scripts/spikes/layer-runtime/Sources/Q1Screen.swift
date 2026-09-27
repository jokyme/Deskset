// Question 1 and the pixel half of question 2: the same System-like skin shown as A (today's view drawing), E1 (one
// E layer), EP (the partition, E groups), D1 / DP (IOSurface contents) and two naive overlapping-layer variants,
// read back from the window server one window at a time and compared pixel by pixel. Also composited over an
// opaque backdrop window (what a person sees over the desktop).
import AppKit
import IOSurface

/// What CA keeps as a layer's contents after drawing: for draw(in:) layers the backing image's format.
func backingInfo(_ layer: CALayer) -> String {
    guard var c = layer.contents else { return "none" }
    var prefix = ""
    if let t = c as? NSObject, NSStringFromClass(type(of: t)) == "CATintedImage" {
        if let tint = t.perform(NSSelectorFromString("tint"))?.takeUnretainedValue() {
            let color = unsafeBitCast(tint, to: CGColor.self)
            prefix = "A8 mask tinted \(colorSpaceName(color.colorSpace)) "
        }
        guard let inner = t.perform(NSSelectorFromString("image"))?.takeUnretainedValue() else { return prefix }
        c = inner
    }
    let o = c as AnyObject
    let type = CFGetTypeID(o as CFTypeRef)
    let description = CFCopyDescription(o as CFTypeRef) as String
    if description.hasPrefix("<CABackingStore") {
        // "<CABackingStore 0x… (buffer [w h] FORMAT) (buffer [w h] FORMAT volatile)>"
        let buffers = description.components(separatedBy: "(buffer ").dropFirst()
            .map { $0.replacingOccurrences(of: ")>", with: "").replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespaces) }
        return prefix + "CABackingStore " + buffers.joined(separator: " + ")
    }
    if type == CGImage.typeID {
        let img = unsafeBitCast(o, to: CGImage.self)
        return prefix + "CGImage \(img.width)x\(img.height) \(img.bitsPerComponent)bpc/\(img.bitsPerPixel)bpp "
            + (img.bitmapInfo.contains(.floatComponents) ? "float " : "") + colorSpaceName(img.colorSpace)
    }
    if type == IOSurfaceGetTypeID() {
        let s = unsafeBitCast(o, to: IOSurfaceRef.self)
        let f = IOSurfaceGetPixelFormat(s)
        let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8(f >> $0 & 0xff) }, encoding: .ascii) ?? "?"
        return prefix + "IOSurface \(IOSurfaceGetWidth(s))x\(IOSurfaceGetHeight(s)) \(fourcc)"
    }
    return prefix + String(describing: Swift.type(of: o))
}

/// Backing formats of all layers under `root`, counted.
func backingSummary(_ root: CALayer) -> [String: Int] {
    var counts: [String: Int] = [:]
    for l in root.sublayers ?? [] { counts[backingInfo(l), default: 0] += 1 }
    return counts
}

/// A pattern like a desktop picture, as an opaque sRGB image `size` × `scale` pixels.
func backdropImage(_ size: CGSize, scale: CGFloat) -> CGImage {
    let ctx = bitmapContext(size, scale: scale)
    let g = CGGradient(colorsSpace: sRGB, colors: [RGBA(40, 90, 160).cg, RGBA(220, 120, 60).cg, RGBA(30, 160, 110).cg]
                       as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
    for i in 0..<12 {
        ctx.setFillColor(RGBA(255, 255, 255, 18 + Double(i % 3) * 20).cg)
        ctx.fill(CGRect(x: CGFloat(i) * 23.3, y: 0, width: 9.7, height: size.height))
    }
    return ctx.makeImage()!
}

/// An opaque window of ours right behind `window`, showing `image`.
func makeBackdrop(for window: NSWindow, image: CGImage) -> NSPanel {
    let b = makePanel(window.frame)
    b.isOpaque = true
    b.backgroundColor = .black
    let v = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
    v.wantsLayer = true
    v.layer?.contents = image
    v.layer?.contentsGravity = .resize
    b.contentView = v
    b.order(.below, relativeTo: window.windowNumber)
    return b
}

/// The skin thread the pixel experiments' windows share (it lives until the process exits).
let sharedSkinThread = RunLoopThread.make("skin")

struct Shot {
    let label: String
    let alone: Pixels
    let overBackdrop: Pixels?
    let format: JSON
    let stable: Bool
}

/// Shows `configs` side by side, waits for them to render, and captures each (alone, and over a backdrop).
func captureModes(_ widget: Widget, _ configs: [Config], tick: Int, backdrops: Bool, columns: Int = 4)
    -> (shots: [Shot], windows: [SkinWindow], backings: JSON) {
    let thread = sharedSkinThread
    var windows: [SkinWindow] = []
    for (i, c) in configs.enumerated() {
        let w = SkinWindow(widget, c, origin: gridOrigin(i, size: widget.size, columns: columns), thread: thread)
        w.buildAndCommit(tick: tick)
        w.show()
        windows.append(w)
    }
    var backdropWindows: [NSPanel] = []
    if backdrops {
        let image = backdropImage(widget.size, scale: windows.first?.scale ?? 2)
        for w in windows { backdropWindows.append(makeBackdrop(for: w.panel, image: image)) }
    }
    pump(1.5)
    var shots: [Shot] = []
    var backings: JSON = [:]
    for (w, c) in zip(windows, configs) {
        guard let first = captureWindow(w.panel) else { continue }
        pump(0.15)
        let second = captureWindow(w.panel)
        let a = Pixels.of(first)
        let stable = second.map { compare(a, Pixels.of($0)).differing == 0 } ?? false
        var over: Pixels?
        if backdrops, let i = windows.firstIndex(where: { $0 === w }),
           let img = captureWindows([w.panel, backdropWindows[i]]) {
            over = Pixels.of(img)
        }
        shots.append(Shot(label: c.label, alone: a, overBackdrop: over, format: describe(first), stable: stable))
        if c.mode.isLayered { backings[c.label] = backingSummary(w.contentRoot) }
    }
    for b in backdropWindows { b.orderOut(nil) }
    return (shots, windows, backings)
}

/// Comparison of two shots, split into pixels inside the partition's group boxes and the rest (base tiles).
func comparison(_ a: Shot, _ b: Shot, groups: [PixelRect]) -> JSON {
    func inGroup(_ x: Int, _ y: Int) -> Bool { groups.contains { $0.contains(x: x, y: y) } }
    var j: JSON = ["all": compare(a.alone, b.alone).json,
                   "inGroupBoxes": compare(a.alone, b.alone, include: inGroup).json,
                   "outsideGroups": compare(a.alone, b.alone) { !inGroup($0, $1) }.json]
    if let x = a.overBackdrop, let y = b.overBackdrop { j["overBackdrop"] = compare(x, y).json }
    return j
}

/// One run shows the same skin in every mode in two window color spaces (the screen's, as Deskset has today, and
/// sRGB), all at once, so any two can be compared.
func q1Screen() -> JSON {
    guard canCapture else { return ["error": "screen capture is not allowed for this process"] }
    let widget = Widgets.system()
    let tick = 7
    let format = choice("--format", FormatChoice.rgba8)
    var names: [String] = []
    var configs: [Config] = []
    for space in [WindowSpace.default, .srgb] {
        let suffix = space == .default ? "" : "@srgb"
        func add(_ name: String, _ m: Mode, surfaceBase: Bool = false, scratch: Bool = false) {
            var c = Config(mode: m)
            c.format = format
            c.windowSpace = space
            c.baseSurface = surfaceBase
            c.scratch = scratch
            configs.append(c)
            names.append(name + suffix)
        }
        add("A", .A)
        add("E1", .E1)
        add("EP", .EP)
        add("EPx", .EP, scratch: true)
        add("D1", .D1)
        add("DP", .DP, surfaceBase: true)
        add("DPx", .DP, surfaceBase: true, scratch: true)
        if space == .default { add("DP(CGImage base)", .DP) }
        add("OVE", .OVE)
        add("OVD", .OVD)
    }
    contextLog.reset()
    let (shots, windows, backings) = captureModes(widget, configs, tick: tick, backdrops: true, columns: 5)
    guard shots.count == configs.count else { return ["error": "capture failed"] }
    let scale = windows[0].scale
    let p = partition(widget, scale: scale)
    let boxes = p.groups.map(\.box)
    func shot(_ n: String) -> Shot { shots[names.firstIndex(of: n)!] }

    var j: JSON = ["widget": "system (260 × 196 pt), tick \(tick)", "partition": p.json, "format": format.rawValue,
                   "configs": Dictionary(uniqueKeysWithValues: zip(names, configs.map(\.label)).map { ($0, $1) }),
                   "captureFormat": shots[0].format, "backingStores": backings,
                   "capturesStable": Dictionary(uniqueKeysWithValues: zip(names, shots.map(\.stable)).map { ($0, $1) })]
    var pairs: JSON = [:]
    for sfx in ["", "@srgb"] {
        for (a, b) in [("EP", "E1"), ("EPx", "E1"), ("E1", "A"), ("EP", "A"), ("D1", "E1"), ("DP", "E1"),
                       ("DP", "D1"), ("DPx", "D1"), ("DPx", "E1"), ("D1", "A"), ("OVE", "E1"), ("OVD", "D1")] {
            pairs["\(a + sfx) vs \(b + sfx)"] = comparison(shot(a + sfx), shot(b + sfx), groups: boxes)
        }
    }
    pairs["DP(CGImage base) vs D1"] = comparison(shot("DP(CGImage base)"), shot("D1"), groups: boxes)
    // Across window color spaces: what a person would see change against today's A.
    for (a, b) in [("E1@srgb", "A"), ("EP@srgb", "A"), ("A@srgb", "A"), ("D1@srgb", "D1"), ("E1@srgb", "E1")] {
        pairs["\(a) vs \(b)"] = comparison(shot(a), shot(b), groups: boxes)
    }
    j["pairs"] = pairs
    // The window server's color matching vs CoreGraphics': the offline sRGB reference converted by CG into the
    // capture's color space (the screen's), against what each mode shows.
    if let screenSpace = windows[0].panel.screen?.colorSpace?.cgColorSpace {
        let converted = Pixels.drawn(renderWidget(widget, tick: tick, scale: scale), in: screenSpace)
        var ref: JSON = [:]
        for n in ["A", "E1", "EP", "D1", "A@srgb", "E1@srgb", "EP@srgb", "D1@srgb"] {
            ref[n] = compare(shot(n).alone, converted).json
        }
        j["vsOfflineSRGBReferenceConvertedByCG"] = ref
    }
    j["contexts"] = contextLog.json
    if let dir = cropDir {
        // Small crops of the top left (title, icon, the AntiAlias=0 subtitle, the CPU pill) and difference maps.
        let region = CGRect(x: 24, y: 20, width: 200, height: 76)
        let screenSpace = windows[0].panel.screen?.colorSpace?.cgColorSpace ?? sRGB
        for n in ["A", "E1@srgb"] {
            writePNG(shot(n).alone.crop(region).image(space: screenSpace),
                     "\(dir)/q1-\(n.replacingOccurrences(of: "@", with: "-")).png")
        }
        for (a, b) in [("E1", "A"), ("EP", "E1"), ("E1@srgb", "A"), ("OVD@srgb", "D1@srgb")] {
            if let d = diffImage(shot(a).alone.crop(region), shot(b).alone.crop(region)) {
                let file = "q1-diff-\(a)-vs-\(b).png".replacingOccurrences(of: "@", with: "-")
                writePNG(d, "\(dir)/\(file)")
            }
        }
    }
    for w in windows { w.close() }
    return j
}
