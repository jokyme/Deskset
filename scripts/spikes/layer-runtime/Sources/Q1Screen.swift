// Question 1 and the pixel half of question 2: the same System-like skin shown as A (the view drawing Deskset used
// until 2026-09-27), B (Deskset's own-bitmap drawing since then), E1 (one
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

/// What `captureModes` saw: one shot per config, and the windows' scale and screen.
struct Capture {
    var shots: [Shot] = []
    var scale: CGFloat = 2
    var screenSpace: CGColorSpace?
    var backings: JSON = [:]
    var windowColorSpaces: [String] = []
}

/// Shows `configs` a few at a time (`batch` windows in a small grid at the bottom right of the screen), waits for
/// them to render, captures each (alone, and over a backdrop), lets `whileOpen` use the batch's windows, and closes
/// them before the next batch. Every capture reads one window (or one window and its backdrop), so the pixels do not
/// depend on what else is on screen.
func captureModes(_ widget: Widget, _ configs: [Config], tick: Int, backdrops: Bool, batch: Int = 4,
                  whileOpen: (([SkinWindow]) -> Void)? = nil) -> Capture {
    let thread = sharedSkinThread
    var result = Capture()
    var first = true
    for chunkStart in stride(from: 0, to: configs.count, by: batch) {
        let chunk = Array(configs[chunkStart..<min(chunkStart + batch, configs.count)])
        var windows: [SkinWindow] = []
        for (i, c) in chunk.enumerated() {
            let w = SkinWindow(widget, c, origin: gridOrigin(i, size: widget.size, columns: 2), thread: thread)
            w.buildAndCommit(tick: tick)
            w.show()
            windows.append(w)
        }
        if first, let w = windows.first {
            result.scale = w.scale
            result.screenSpace = w.panel.screen?.colorSpace?.cgColorSpace
            first = false
        }
        var backdropWindows: [NSPanel] = []
        if backdrops {
            let image = backdropImage(widget.size, scale: windows.first?.scale ?? 2)
            for w in windows { backdropWindows.append(makeBackdrop(for: w.panel, image: image)) }
        }
        pump(1.5)
        for (i, (w, c)) in zip(windows, chunk).enumerated() {
            result.windowColorSpaces.append(w.panel.colorSpace?.localizedName ?? "none")
            guard let firstImage = captureWindow(w.panel) else { continue }
            pump(0.15)
            let second = captureWindow(w.panel)
            let a = Pixels.of(firstImage)
            let stable = second.map { compare(a, Pixels.of($0)).differing == 0 } ?? false
            var over: Pixels?
            if backdrops, let img = captureWindows([w.panel, backdropWindows[i]]) {
                over = Pixels.of(img)
            }
            result.shots.append(Shot(label: c.label, alone: a, overBackdrop: over, format: describe(firstImage),
                                     stable: stable))
            if c.mode.isLayered { result.backings[c.label] = backingSummary(w.contentRoot) }
        }
        for b in backdropWindows { b.orderOut(nil) }
        whileOpen?(windows)
        for w in windows { w.close() }
        pump(0.3)
    }
    return result
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
/// sRGB), a few windows at a time, so any two can be compared.
func q1Screen() -> JSON {
    if flag("--stepped") { return q1Stepped() }
    guard canCapture else { return ["error": "screen capture is not allowed for this process"] }
    let widget = Widgets.system()
    let tick = 7
    let format = choice("--format", FormatChoice.rgba8)
    var names: [String] = []
    var configs: [Config] = []
    for space in [WindowSpace.default, .srgb] {
        let suffix = space == .default ? "" : "@srgb"
        func add(_ name: String, _ m: Mode, surfaceBase: Bool = false, scratch: Bool = false,
                 windowSpaceBase: Bool = false, cgImages: Bool = false) {
            var c = Config(mode: m)
            c.format = format
            c.windowSpace = space
            c.baseSurface = surfaceBase
            c.scratch = scratch
            c.baseInWindowSpace = windowSpaceBase
            c.cgImages = cgImages
            configs.append(c)
            names.append(name + suffix)
        }
        add("A", .A)
        add("B", .B)
        add("E1", .E1)
        add("EP", .EP)
        add("EPx", .EP, scratch: true)
        add("D1", .D1)
        add("DP", .DP, surfaceBase: true)
        add("DPx", .DP, surfaceBase: true, scratch: true)
        if space == .default {
            add("DP(CGImage base)", .DP)
            // The partition with its base (and scratch) bitmap in the window's color space, like B's own bitmap.
            add("EPw", .EP, windowSpaceBase: true)
            add("EPxw", .EP, scratch: true, windowSpaceBase: true)
            // C: our own bitmaps (in the window's color space) as the contents, like B but per layer.
            add("CPw", .DP, windowSpaceBase: true, cgImages: true)
            add("CPxw", .DP, scratch: true, windowSpaceBase: true, cgImages: true)
        }
        add("C1", .D1, cgImages: true)
        add("CP", .DP, cgImages: true)
        add("OVE", .OVE)
        add("OVD", .OVD)
    }
    contextLog.reset()
    let capture = captureModes(widget, configs, tick: tick, backdrops: true)
    let shots = capture.shots, backings = capture.backings
    guard shots.count == configs.count else { return ["error": "capture failed"] }
    let scale = capture.scale
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
                       ("DP", "D1"), ("DPx", "D1"), ("DPx", "E1"), ("D1", "A"), ("OVE", "E1"), ("OVD", "D1"),
                       ("B", "A"), ("E1", "B"), ("EP", "B"), ("EPx", "B"), ("D1", "B")] {
            pairs["\(a + sfx) vs \(b + sfx)"] = comparison(shot(a + sfx), shot(b + sfx), groups: boxes)
        }
    }
    pairs["DP(CGImage base) vs D1"] = comparison(shot("DP(CGImage base)"), shot("D1"), groups: boxes)
    for (a, b) in [("EPw", "E1"), ("EPw", "B"), ("EPxw", "E1"), ("EPxw", "B"), ("EPw", "A"), ("C1", "B"),
                   ("CPw", "B"), ("CPxw", "B"), ("C1@srgb", "E1@srgb"), ("CP@srgb", "E1@srgb"), ("CP@srgb", "C1@srgb"),
                   ("C1@srgb", "B"), ("C1", "E1"), ("CPw", "EPw")] {
        pairs["\(a) vs \(b)"] = comparison(shot(a), shot(b), groups: boxes)
    }
    // Across window color spaces: what a person would see change against today's A.
    for (a, b) in [("E1@srgb", "A"), ("EP@srgb", "A"), ("A@srgb", "A"), ("D1@srgb", "D1"), ("E1@srgb", "E1"),
                   ("E1@srgb", "B"), ("EP@srgb", "B"), ("EPx@srgb", "B"), ("D1@srgb", "B"), ("B@srgb", "B")] {
        pairs["\(a) vs \(b)"] = comparison(shot(a), shot(b), groups: boxes)
    }
    j["pairs"] = pairs
    // The window server's color matching vs CoreGraphics': the offline sRGB reference converted by CG into the
    // capture's color space (the screen's), against what each mode shows.
    if let screenSpace = capture.screenSpace {
        let converted = Pixels.drawn(renderWidget(widget, tick: tick, scale: scale), in: screenSpace)
        var ref: JSON = [:]
        for n in ["A", "B", "E1", "EP", "D1", "A@srgb", "B@srgb", "E1@srgb", "EP@srgb", "D1@srgb"] {
            ref[n] = compare(shot(n).alone, converted).json
        }
        j["vsOfflineSRGBReferenceConvertedByCG"] = ref
    }
    j["contexts"] = contextLog.json
    if let dir = cropDir {
        // Small crops of the top left (title, icon, the AntiAlias=0 subtitle, the CPU pill) and difference maps.
        let region = CGRect(x: 24, y: 20, width: 200, height: 76)
        let screenSpace = capture.screenSpace ?? sRGB
        for n in ["A", "E1@srgb"] {
            writePNG(shot(n).alone.crop(region).image(space: screenSpace),
                     "\(dir)/q1-\(n.replacingOccurrences(of: "@", with: "-")).png")
        }
        for (a, b) in [("E1", "A"), ("EP", "E1"), ("E1@srgb", "A"), ("OVD@srgb", "D1@srgb"), ("B", "A"),
                       ("E1@srgb", "B")] {
            if let d = diffImage(shot(a).alone.crop(region), shot(b).alone.crop(region)) {
                let file = "q1-diff-\(a)-vs-\(b).png".replacingOccurrences(of: "@", with: "-")
                writePNG(d, "\(dir)/\(file)")
            }
        }
    }
    return j
}

/// `q1 --stepped`: question 1 against what Deskset actually shows. The plain q1 builds every window directly at tick
/// 7 and draws it once, so B there is B drawn in full (Deskset keeps pictures of unchanged elements: B+kept) and A
/// is A drawn once (an A skin that keeps redrawing moves onto Core Animation's accelerated path, `memtrace`). Here
/// every window starts at tick 0 and is stepped through ticks 1…7 (a redraw each), so B+kept has made and copied its
/// pictures and E layers have their second buffers; A is also captured after 10 more redraws at tick 7 and after
/// 2 s of redraws at 60 Hz, next to A drawn once at tick 7. Default window color space (Deskset's), System widget.
func q1Stepped() -> JSON {
    guard canCapture else { return ["error": "screen capture is not allowed for this process"] }
    let widget = Widgets.system()
    let tick = 7
    struct Entry {
        let name: String
        let config: Config
        let stepped: Bool
        var extraRedraws = 0
        var sixtyHzSeconds = 0.0
    }
    func config(_ m: Mode, kept: Bool = false, windowSpaceBase: Bool = false, scratch: Bool = false,
                cgImages: Bool = false, format: FormatChoice = .rgba8) -> Config {
        var c = Config(mode: m)
        c.keptPictures = kept
        c.baseInWindowSpace = windowSpaceBase
        c.scratch = scratch
        c.cgImages = cgImages
        c.format = format
        return c
    }
    let entries: [Entry] = [
        Entry(name: "A drawn once", config: config(.A), stepped: false),
        Entry(name: "A redrawn", config: config(.A), stepped: true, extraRedraws: 10),
        Entry(name: "A at 60 Hz", config: config(.A), stepped: true, sixtyHzSeconds: 2),
        Entry(name: "B", config: config(.B), stepped: true),
        Entry(name: "B+kept", config: config(.B, kept: true), stepped: true),
        Entry(name: "B+kept drawn once", config: config(.B, kept: true), stepped: false),
        Entry(name: "E1", config: config(.E1), stepped: true),
        Entry(name: "EPw", config: config(.EP, windowSpaceBase: true), stepped: true),
        Entry(name: "EPxw", config: config(.EP, windowSpaceBase: true, scratch: true), stepped: true),
        Entry(name: "C1", config: config(.D1, cgImages: true), stepped: true),
        Entry(name: "CPw", config: config(.DP, windowSpaceBase: true, cgImages: true), stepped: true),
        Entry(name: "E1 RGBA16Float", config: config(.E1, format: .rgba16f), stepped: true),
    ]
    var shots: [String: Pixels] = [:]
    var stable: [String: Bool] = [:]
    var kept: JSON = [:]
    var screenSpace: CGColorSpace?
    let batch = 4
    for start in stride(from: 0, to: entries.count, by: batch) {
        let chunk = Array(entries[start..<min(start + batch, entries.count)])
        var windows: [SkinWindow] = []
        for (i, e) in chunk.enumerated() {
            let w = SkinWindow(widget, e.config, origin: gridOrigin(i, size: widget.size, columns: 2),
                               thread: sharedSkinThread)
            w.buildAndCommit(tick: e.stepped ? 0 : tick)
            w.show()
            windows.append(w)
        }
        screenSpace = screenSpace ?? windows.first?.panel.screen?.colorSpace?.cgColorSpace
        pump(0.6)
        for t in 1...tick {
            for (w, e) in zip(windows, chunk) where e.stepped {
                if e.config.mode.isView { w.step() } else { w.onSkinSync { w.step() } }
                _ = t
            }
            pump(0.15)
        }
        for (w, e) in zip(windows, chunk) {
            for _ in 0..<e.extraRedraws {
                w.drawView?.needsDisplay = true
                pump(0.05)
            }
            if e.sixtyHzSeconds > 0, let v = w.drawView {
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in v.needsDisplay = true }
                RunLoop.main.add(timer, forMode: .common)
                pump(e.sixtyHzSeconds)
                timer.invalidate()
            }
        }
        pump(1.5)
        for (w, e) in zip(windows, chunk) {
            guard let first = captureWindow(w.panel) else { continue }
            pump(0.15)
            let a = Pixels.of(first)
            stable[e.name] = captureWindow(w.panel).map { compare(a, Pixels.of($0)).differing == 0 } ?? false
            shots[e.name] = a
            if let v = w.drawView, v.keptPictures {
                let k = v.keptStats
                var entry: JSON = ["picturesCopied": k.copied, "picturesMade": k.made, "elementsDrawn": k.drawn,
                                   "elements": widget.elements.count, "tick": w.tick]
                if let c = v.keptCheck(tick: w.tick) { entry["lastPictureVsFullDrawingOffline"] = c }
                kept[e.name] = entry
            }
        }
        for w in windows { w.close() }
        pump(0.3)
    }
    guard shots.count == entries.count else { return ["error": "capture failed", "captured": Array(shots.keys)] }
    let p = partition(widget, scale: 2)
    func cmp(_ a: String, _ b: String) -> JSON {
        guard let x = shots[a], let y = shots[b] else { return [:] }
        let boxes = p.groups.map(\.box)
        func inGroup(_ px: Int, _ py: Int) -> Bool { boxes.contains { $0.contains(x: px, y: py) } }
        return ["all": compare(x, y).json, "inGroupBoxes": compare(x, y, include: inGroup).json,
                "outsideGroups": compare(x, y) { !inGroup($0, $1) }.json]
    }
    var pairs: JSON = [:]
    for (a, b) in [("E1", "B+kept"), ("EPw", "B+kept"), ("EPxw", "B+kept"), ("C1", "B+kept"), ("CPw", "B+kept"),
                   ("B", "B+kept"), ("B+kept drawn once", "B+kept"), ("E1", "B"), ("EPw", "B"), ("EPxw", "B"),
                   ("EPw", "E1"), ("CPw", "EPw"),
                   ("A redrawn", "A drawn once"), ("A at 60 Hz", "A drawn once"), ("A at 60 Hz", "A redrawn"),
                   ("E1 RGBA16Float", "A drawn once"), ("E1 RGBA16Float", "A redrawn"), ("E1 RGBA16Float", "A at 60 Hz"),
                   ("B", "A drawn once"), ("B", "A redrawn"), ("B+kept", "A redrawn"), ("B+kept", "A at 60 Hz"),
                   ("E1", "A redrawn")] {
        pairs["\(a) vs \(b)"] = cmp(a, b)
    }
    var j: JSON = ["widget": "system (260 × 196 pt), tick \(tick), default window color space",
                   "steps": "windows built at tick 0 and stepped to tick \(tick) (a redraw per tick, 0.15 s apart), "
                       + "except the ones marked drawn once (built at tick \(tick))",
                   "pairs": pairs, "capturesStable": stable, "keptPictures": kept,
                   "screenColorSpace": colorSpaceName(screenSpace)]
    if let dir = cropDir {
        let region = CGRect(x: 24, y: 20, width: 200, height: 76)
        for (a, b) in [("E1", "B+kept"), ("A redrawn", "A drawn once")] {
            if let x = shots[a], let y = shots[b], let d = diffImage(x.crop(region), y.crop(region)) {
                writePNG(d, "\(dir)/q1s-diff-\(a)-vs-\(b).png".replacingOccurrences(of: " ", with: "-"))
            }
            // The whole window too.
            if let x = shots[a], let y = shots[b], let d = diffImage(x, y) {
                writePNG(d, "\(dir)/q1s-diff-full-\(a)-vs-\(b).png".replacingOccurrences(of: " ", with: "-"))
            }
        }
        for n in ["A drawn once", "A redrawn"] {
            if let x = shots[n] {
                writePNG(x.image(space: screenSpace ?? sRGB), "\(dir)/q1s-\(n).png".replacingOccurrences(of: " ", with: "-"))
            }
        }
    }
    return j
}
