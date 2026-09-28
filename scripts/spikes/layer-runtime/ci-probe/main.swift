// CARenderer probe: can this machine composite Core Animation layer trees offscreen, are the pixels the same as on
// another machine, and how long does one render take? This is question 8 of the H1 experiment: whether the planned
// pixel gate that renders a one-layer tree and a partitioned tree with CARenderer and compares them can run on the
// CI runners (macos-26 on Apple silicon, macos-26-intel).
//
// What it does, all from code (no files, no fonts other than Helvetica):
//   1. Looks for a Metal device (MTLCreateSystemDefaultDevice). Without one it writes its report and exits with 4
//      ("not run"): CARenderer has no other supported back end.
//   2. Renders a fixed set of layer trees at 1x and 2x into an sRGB BGRA8 Metal texture, waits for the GPU, reads the
//      texture back (top row first) and hashes the bytes (SHA-256):
//        image      one layer showing an image made from integer math, pixel for pixel: must equal the image exactly
//        solids     flat colors, some translucent and overlapping, and a group with opacity (GPU blending)
//        vector     what Core Animation draws itself: rounded corners, a border, a shadow, a shape layer, a rotated
//                   layer, a gradient layer, a mask, fractional positions
//        cg         one layer showing a CoreGraphics bitmap (gradient, translucent panel, text): the compositor only
//                   copies it, so differences here come from CoreGraphics / CoreText, not from the GPU
//        g2-single  the pixel gate's reference: a widget (gradient panel with values, a bar, a ring, a chart) as one
//                   layer showing one bitmap
//        g2-tiles   the same widget partitioned as the plan does it: base tiles that all show one base bitmap through
//                   contentsRect, and one layer per group showing that group's pixels (bitmaps as contents)
//        g2-e       the same partition with group layers that paint in draw(in:) (CA's own backing stores)
//      It checks image == its source, cg == its source, g2-single == its source, g2-tiles == g2-single and
//      g2-e == g2-single.
//   3. With --reference DIR (an earlier run's --out), compares every scene with that run's pixels.
//   4. Times renders of the partitioned widget: --rounds rounds (default 3) of --renders renders (default 20) in
//      several ways (same tree again, a new tree each time, a new renderer each time), with the load average before
//      and after each round. Before every timed render the texture is overwritten with garbage, and every read-back
//      must hash like the first render, so a render that silently did nothing would show.
//
// Output: a summary on stdout; with --out DIR also DIR/probe.json and, per scene, the raw pixels (BGRA, premultiplied,
// top row first, zlib-compressed: <scene>.bgra.zlib) and a PNG to look at.
// Exit status: 0 ran; 4 no Metal device (not run); 3 timed out (not run; every thread's stack is printed first, with
// /usr/bin/sample); 1 error.
import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Metal
import QuartzCore

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Options

struct Options {
    var out: URL?
    var reference: URL?
    var rounds = 3
    var renders = 20
    var timeout: Double = 300
}

func usage() -> Never {
    print("""
    usage: probe [--out DIR] [--reference DIR] [--rounds N] [--renders N] [--timeout SECONDS]
      --out DIR        write probe.json and every scene's pixels there
      --reference DIR  compare every scene with the pixels an earlier run wrote with --out
      --rounds N       timing rounds (default 3)
      --renders N      renders per timing round and way (default 20)
      --timeout S      give up after S seconds, print every thread's stack and exit with 3 (default 300)
    """)
    exit(1)
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst()
    func value(_ name: String) -> String {
        guard let v = args.popFirst() else { print("\(name) needs a value"); usage() }
        return v
    }
    while let a = args.popFirst() {
        switch a {
        case "--out": o.out = URL(fileURLWithPath: value(a))
        case "--reference": o.reference = URL(fileURLWithPath: value(a))
        case "--rounds": guard let n = Int(value(a)), n > 0 else { usage() }; o.rounds = n
        case "--renders": guard let n = Int(value(a)), n > 0 else { usage() }; o.renders = n
        case "--timeout": guard let s = Double(value(a)), s > 0 else { usage() }; o.timeout = s
        default: usage()
        }
    }
    return o
}

let options = parseOptions()

// MARK: Report

typealias JSON = [String: Any]

final class Report {
    private let lock = NSLock()
    private var j: JSON = ["probe": "h1-carenderer", "version": 1]
    private(set) var stage = "start"

    subscript(key: String) -> Any? {
        get { lock.lock(); defer { lock.unlock() }; return j[key] }
        set { lock.lock(); j[key] = newValue; lock.unlock() }
    }

    func setStage(_ s: String) {
        lock.lock(); stage = s; j["stage"] = s; lock.unlock()
        print("[\(String(format: "%7.2f", CACurrentMediaTime() - startTime)) s] \(s)")
    }

    func write() {
        guard let out = options.out else { return }
        lock.lock(); let copy = j; lock.unlock()
        let data = (try? JSONSerialization.data(withJSONObject: copy, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        try? data.write(to: out.appendingPathComponent("probe.json"))
    }
}

let startTime = CACurrentMediaTime()
let report = Report()
if let out = options.out {
    try? FileManager.default.createDirectory(at: out.appendingPathComponent("scenes"),
                                             withIntermediateDirectories: true)
}

func finish(_ status: String, _ code: Int32) -> Never {
    report["status"] = status
    report["seconds"] = r(CACurrentMediaTime() - startTime, 2)
    report.write()
    print("status: \(status) (exit \(code))")
    exit(code)
}

/// Rounds to `digits` decimals so the JSON stays readable.
func r(_ v: Double, _ digits: Int = 3) -> Double {
    guard v.isFinite else { return 0 }
    let p = pow(10, Double(digits))
    return (v * p).rounded() / p
}

// MARK: Watchdog

/// A probe that hangs (a system service that never answers, as the Intel runner's icon service once did) must not
/// hold the job until its time limit: after `--timeout` seconds print every thread's stack and exit with 3.
func startWatchdog() {
    let t = Thread {
        Thread.sleep(forTimeInterval: options.timeout)
        print("TIMEOUT: still at \"\(report.stage)\" after \(Int(options.timeout)) s; counts as not run. Stacks:")
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = ["\(getpid())", "1"]
        try? sample.run()
        sample.waitUntilExit()
        finish("timeout", 3)
    }
    t.stackSize = 1 << 20
    t.start()
}
startWatchdog()

// MARK: Environment

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

func sysctlInt(_ name: String) -> Int64? {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
    return size == 4 ? Int64(Int32(truncatingIfNeeded: v)) : v
}

func loadAverage() -> [Double] {
    var l = [Double](repeating: 0, count: 3)
    getloadavg(&l, 3)
    return l.map { r($0, 2) }
}

#if arch(arm64)
let builtArch = "arm64"
#else
let builtArch = "x86_64"
#endif

func environment() -> JSON {
    var e: JSON = [
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "binaryArch": builtArch,
        "cpus": ProcessInfo.processInfo.processorCount,
        "memoryGB": r(Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824, 1),
        "loadAverage": loadAverage(),
    ]
    e["model"] = sysctlString("hw.model")
    e["cpu"] = sysctlString("machdep.cpu.brand_string")
    e["osBuild"] = sysctlString("kern.osversion")
    e["virtualMachine"] = sysctlInt("kern.hv_vmm_present").map { $0 == 1 }
    e["rosetta"] = (sysctlInt("sysctl.proc_translated") ?? 0) == 1
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    if CGGetActiveDisplayList(16, &ids, &count) == .success {
        e["displays"] = (0..<Int(count)).map { i -> JSON in
            let id = ids[i]
            var d: JSON = ["pixels": "\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))", "main": CGDisplayIsMain(id) != 0]
            if let mode = CGDisplayCopyDisplayMode(id) { d["points"] = "\(mode.width)x\(mode.height)" }
            d["colorSpace"] = CGDisplayCopyColorSpace(id).name.map { $0 as String } ?? "unnamed"
            return d
        }
    }
    return e
}

func describe(_ d: MTLDevice) -> JSON {
    var j: JSON = [
        "name": d.name,
        "registryID": String(d.registryID, radix: 16),
        "lowPower": d.isLowPower,
        "headless": d.isHeadless,
        "removable": d.isRemovable,
        "unifiedMemory": d.hasUnifiedMemory,
        "recommendedMaxWorkingSetMB": Int(d.recommendedMaxWorkingSetSize / 1_048_576),
    ]
    var families: [String] = []
    for (name, f) in [("apple7", MTLGPUFamily.apple7), ("apple8", .apple8), ("apple9", .apple9), ("mac2", .mac2)]
        where d.supportsFamily(f) { families.append(name) }
    j["families"] = families
    switch d.location {
    case .builtIn: j["location"] = "built-in"
    case .slot: j["location"] = "slot"
    case .external: j["location"] = "external"
    case .unspecified: j["location"] = "unspecified"
    @unknown default: j["location"] = "other"
    }
    return j
}

// MARK: Pixels

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}

func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// RGBA (premultiplied, as CoreGraphics writes it) to BGRA (as the BGRA8 texture holds it).
func bgra(fromRGBA b: [UInt8]) -> [UInt8] {
    var o = b
    for i in stride(from: 0, to: b.count, by: 4) {
        o[i] = b[i + 2]
        o[i + 2] = b[i]
    }
    return o
}

/// How two BGRA images of the same size differ.
func diff(_ a: [UInt8], _ b: [UInt8], width w: Int, height h: Int) -> JSON {
    guard a.count == b.count, a.count == w * h * 4 else { return ["sizeMismatch": true] }
    var maxChannel = 0, differing = 0
    var histogram = [0, 0, 0, 0, 0]
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    a.withUnsafeBufferPointer { pa in
        b.withUnsafeBufferPointer { pb in
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    var m = 0
                    for c in 0..<4 { m = max(m, abs(Int(pa[i + c]) - Int(pb[i + c]))) }
                    if m > 0 {
                        differing += 1
                        maxChannel = max(maxChannel, m)
                        histogram[m >= 8 ? 4 : m >= 4 ? 3 : m - 1] += 1
                        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
            }
        }
    }
    var j: JSON = ["maxChannelDiff": maxChannel, "differingPixels": differing, "pixels": w * h,
                   "differingPercent": r(Double(differing) * 100 / Double(w * h), 3),
                   "byMaxDiff": ["1": histogram[0], "2": histogram[1], "3": histogram[2], "4-7": histogram[3],
                                 "8+": histogram[4]]]
    if differing > 0 { j["bounds"] = "x \(minX)–\(maxX), y \(minY)–\(maxY)" }
    return j
}

func summary(_ d: JSON) -> String {
    if d["sizeMismatch"] != nil { return "size mismatch" }
    let n = d["differingPixels"] as? Int ?? -1
    return n == 0 ? "identical" : "max \(d["maxChannelDiff"] ?? "?"), \(n) px (\(d["differingPercent"] ?? "?") %)"
}

func writePixels(_ bytes: [UInt8], width w: Int, height h: Int, name: String) {
    guard let out = options.out?.appendingPathComponent("scenes") else { return }
    if let z = try? (Data(bytes) as NSData).compressed(using: .zlib) {
        try? (z as Data).write(to: out.appendingPathComponent("\(name).bgra.zlib"))
    }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                              space: sRGB, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent("\(name).png") as CFURL,
                                                     "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func readPixels(_ dir: URL, name: String) -> [UInt8]? {
    let url = dir.appendingPathComponent("scenes").appendingPathComponent("\(name).bgra.zlib")
    guard let z = try? Data(contentsOf: url), let raw = try? (z as NSData).decompressed(using: .zlib) else { return nil }
    return [UInt8](raw as Data)
}

// MARK: Content

/// The canvas in points. At 2x the renders are 640 × 480 pixels, about a default widget at 2x.
let W: CGFloat = 320, H: CGFloat = 240

/// An sRGB, 8-bit, premultiplied RGBA bitmap context whose user space is points at `scale` with y pointing down.
func pointContext(_ size: CGSize, scale: CGFloat) -> CGContext {
    let pw = Int(size.width * scale), ph = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(ph))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSmoothing(false)
    ctx.interpolationQuality = .high
    return ctx
}

/// The context's pixels (RGBA, premultiplied, top row first).
func contextBytes(_ ctx: CGContext) -> [UInt8] {
    let pw = ctx.width, ph = ctx.height, row = ctx.bytesPerRow
    let base = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var out = [UInt8](repeating: 0, count: pw * ph * 4)
    for y in 0..<ph {
        for i in 0..<(pw * 4) { out[y * pw * 4 + i] = base[y * row + i] }
    }
    return out
}

func rgbaImage(_ bytes: [UInt8], _ pw: Int, _ ph: Int) -> CGImage {
    CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pw * 4, space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
}

/// Pixels from integer math only (the same on every machine), with opaque, translucent and clear areas.
func patternBytes(_ pw: Int, _ ph: Int) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: pw * ph * 4)
    let alphas = [255, 255, 200, 128, 37, 0]
    for y in 0..<ph {
        for x in 0..<pw {
            let a = alphas[(x / 24 + y / 20) % alphas.count]
            let rgb = [(x * 7 + y * 3) & 255, (x ^ y) & 255, (x * y / 3) & 255]
            let i = (y * pw + x) * 4
            for c in 0..<3 { b[i + c] = UInt8((rgb[c] * a + 127) / 255) }
            b[i + 3] = UInt8(a)
        }
    }
    return b
}

var fontNames: [String: String] = [:]

func drawText(_ ctx: CGContext, _ s: String, x: CGFloat, baseline: CGFloat, size: CGFloat, color c: CGColor,
              bold: Bool = false) {
    let requested = bold ? "Helvetica-Bold" : "Helvetica"
    let font = CTFontCreateWithName(requested as CFString, size, nil)
    fontNames[requested] = CTFontCopyPostScriptName(font) as String
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): c,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, ctx)
}

/// The widget's panel: a rounded rectangle with a vertical gradient (like the default skins' StylePanel) and a
/// hairline border, translucent.
func drawPanel(_ ctx: CGContext, _ rect: CGRect) {
    let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: sRGB, colors: [color(0.17, 0.18, 0.22, 0.84), color(0.09, 0.10, 0.12, 0.92)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(color(1, 1, 1, 0.14))
    ctx.setLineWidth(1)
    ctx.strokePath()
}

/// The widget's groups (points, y down) and what each shows. Every element stays inside its group.
let g2Groups: [CGRect] = [
    CGRect(x: 16, y: 12, width: 150, height: 32),   // time
    CGRect(x: 16, y: 52, width: 180, height: 14),   // bar
    CGRect(x: 222, y: 14, width: 84, height: 84),   // ring
    CGRect(x: 16, y: 80, width: 190, height: 144),  // chart
    CGRect(x: 222, y: 110, width: 84, height: 114), // list
]

func drawG2Elements(_ ctx: CGContext) {
    let accent = color(0.30, 0.62, 1.0)
    let text = color(0.96, 0.97, 1.0)
    let dim = color(1, 1, 1, 0.55)
    for (i, g) in g2Groups.enumerated() {
        ctx.saveGState()
        ctx.clip(to: g)
        switch i {
        case 0:
            drawText(ctx, "12:34", x: g.minX + 1, baseline: g.minY + 25, size: 26, color: text, bold: true)
            drawText(ctx, "PM", x: g.minX + 82, baseline: g.minY + 25, size: 12, color: dim)
        case 1:
            let bg = CGPath(roundedRect: g.insetBy(dx: 0, dy: 3), cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(bg); ctx.setFillColor(color(1, 1, 1, 0.12)); ctx.fillPath()
            var fill = g.insetBy(dx: 0, dy: 3); fill.size.width *= 0.63
            ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.setFillColor(accent); ctx.fillPath()
        case 2:
            let c = CGPoint(x: g.midX + 0.3, y: g.midY - 0.2), radius: CGFloat = 34
            ctx.setLineWidth(7)
            ctx.addArc(center: c, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            ctx.setStrokeColor(color(1, 1, 1, 0.15)); ctx.strokePath()
            ctx.setLineCap(.round)
            ctx.addArc(center: c, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + 0.42 * 2 * .pi,
                       clockwise: false)
            ctx.setStrokeColor(accent); ctx.strokePath()
            drawText(ctx, "42%", x: c.x - 15, baseline: c.y + 5, size: 14, color: text, bold: true)
        case 3:
            let chart = CGMutablePath()
            var points: [CGPoint] = []
            for k in 0..<40 {
                let x = g.minX + 4 + CGFloat(k) * (g.width - 8) / 39
                let v = 0.5 + 0.3 * sin(Double(k) * 0.45) + 0.15 * sin(Double(k) * 1.7 + 1)
                points.append(CGPoint(x: x, y: g.maxY - 6 - CGFloat(v) * (g.height - 30)))
            }
            chart.addLines(between: points)
            let area = chart.mutableCopy()!
            area.addLine(to: CGPoint(x: points.last!.x, y: g.maxY - 4))
            area.addLine(to: CGPoint(x: points.first!.x, y: g.maxY - 4))
            area.closeSubpath()
            ctx.addPath(area); ctx.setFillColor(color(0.30, 0.62, 1.0, 0.25)); ctx.fillPath()
            ctx.addPath(chart); ctx.setStrokeColor(accent); ctx.setLineWidth(1.5); ctx.setLineJoin(.round)
            ctx.strokePath()
            drawText(ctx, "Network  1.2 MB/s", x: g.minX + 4, baseline: g.minY + 14, size: 11, color: dim)
        default:
            for (k, (label, value)) in [("CPU", "42%"), ("GPU", "17%"), ("RAM", "11.8 GB"), ("SSD", "61%")].enumerated() {
                let y = g.minY + 20 + CGFloat(k) * 26
                drawText(ctx, label, x: g.minX + 4, baseline: y, size: 11, color: dim)
                drawText(ctx, value, x: g.minX + 36, baseline: y, size: 12, color: text, bold: true)
            }
        }
        ctx.restoreGState()
    }
}

struct PixelRect {
    var x0, y0, x1, y1: Int
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    var cg: CGRect { CGRect(x: x0, y: y0, width: width, height: height) }
    func points(_ scale: CGFloat) -> CGRect {
        CGRect(x: CGFloat(x0) / scale, y: CGFloat(y0) / scale, width: CGFloat(width) / scale,
               height: CGFloat(height) / scale)
    }
    static func of(_ rect: CGRect, scale: CGFloat) -> PixelRect {
        PixelRect(x0: Int((rect.minX * scale).rounded(.down)), y0: Int((rect.minY * scale).rounded(.down)),
                  x1: Int((rect.maxX * scale).rounded(.up)), y1: Int((rect.maxY * scale).rounded(.up)))
    }
}

/// The window minus `holes`, as disjoint whole-pixel rectangles (row bands; equal spans of neighboring bands merged).
func tiles(_ window: PixelRect, minus holes: [PixelRect]) -> [PixelRect] {
    var ys = Set([window.y0, window.y1])
    for h in holes { ys.insert(h.y0); ys.insert(h.y1) }
    let bands = ys.sorted()
    var done: [PixelRect] = []
    var open: [Int: PixelRect] = [:]
    for k in 0..<(bands.count - 1) {
        let y0 = bands[k], y1 = bands[k + 1]
        let covering = holes.filter { $0.y0 < y1 && $0.y1 > y0 }.map { ($0.x0, $0.x1) }.sorted { $0.0 < $1.0 }
        var spans: [(Int, Int)] = []
        var x = window.x0
        for (a, b) in covering {
            if a > x { spans.append((x, a)) }
            x = max(x, b)
        }
        if x < window.x1 { spans.append((x, window.x1)) }
        var next: [Int: PixelRect] = [:]
        for (a, b) in spans {
            let key = a << 20 | b
            if var t = open[key], t.y1 == y0 {
                t.y1 = y1
                next[key] = t
                open[key] = nil
            } else {
                next[key] = PixelRect(x0: a, y0: y0, x1: b, y1: y1)
            }
        }
        done += open.values
        open = next
    }
    return done + open.values
}

// MARK: Layer trees

final class QuietLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }
}

var drawContexts: [String] = []

/// A group layer that paints its pixels itself in draw(in:) into CA's backing store (the plan's approach E).
final class PaintLayer: CALayer {
    var image: CGImage?
    override func action(forKey event: String) -> CAAction? { NSNull() }
    override func draw(in ctx: CGContext) {
        let space = ctx.colorSpace?.name.map { $0 as String } ?? "none"
        let note = "\(space), \(ctx.bitsPerComponent) bpc"
        if !drawContexts.contains(note) { drawContexts.append(note) }
        guard let image else { return }
        // Draw the image upright whichever way the context points.
        if ctx.ctm.d < 0 {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: bounds)
    }
}

/// The tree the renderer sees: a top layer in pixels (flipped, so y points down like a skin), and inside it a layer
/// in points under a `scale` transform, like a window's content at that backing scale.
func makeTree(scale: CGFloat, _ fill: (CALayer) -> Void) -> CALayer {
    CATransaction.setDisableActions(true)
    let top = QuietLayer()
    top.anchorPoint = .zero
    top.bounds = CGRect(x: 0, y: 0, width: W * scale, height: H * scale)
    top.isGeometryFlipped = true
    let root = QuietLayer()
    root.anchorPoint = .zero
    root.bounds = CGRect(x: 0, y: 0, width: W, height: H)
    root.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    top.addSublayer(root)
    fill(root)
    return top
}

func imageLayer(_ image: Any, frame: CGRect, scale: CGFloat) -> CALayer {
    let l = QuietLayer()
    l.anchorPoint = .zero
    l.contentsScale = scale
    l.frame = frame
    l.contents = image
    l.contentsGravity = .resize
    l.magnificationFilter = .nearest
    l.minificationFilter = .nearest
    return l
}

func solid(_ frame: CGRect, _ c: CGColor) -> CALayer {
    let l = QuietLayer()
    l.frame = frame
    l.backgroundColor = c
    return l
}

func solidsScene(_ root: CALayer, scale: CGFloat) {
    root.addSublayer(solid(CGRect(x: 0, y: 0, width: 320, height: 150), color(0.12, 0.14, 0.18)))
    root.addSublayer(solid(CGRect(x: 20, y: 20, width: 120, height: 80), color(0.9, 0.3, 0.2)))
    root.addSublayer(solid(CGRect(x: 80, y: 50, width: 140, height: 100), color(0.2, 0.6, 0.9, 0.5)))
    root.addSublayer(solid(CGRect(x: 200, y: 10, width: 100, height: 200), color(1, 1, 1, 0.25)))
    root.addSublayer(solid(CGRect(x: 10, y: 170, width: 90, height: 60), color(0.95, 0.8, 0.1, 0.7)))
    let group = QuietLayer()
    group.frame = CGRect(x: 60, y: 120, width: 200, height: 110)
    group.opacity = 0.6
    group.addSublayer(solid(CGRect(x: 0, y: 0, width: 120, height: 80), color(0.1, 0.8, 0.4)))
    group.addSublayer(solid(CGRect(x: 60, y: 30, width: 140, height: 80), color(0.7, 0.2, 0.9, 0.8)))
    root.addSublayer(group)
}

func vectorScene(_ root: CALayer, scale: CGFloat) {
    root.addSublayer(solid(CGRect(x: 0, y: 0, width: 320, height: 240), color(0.93, 0.94, 0.96)))

    let card = QuietLayer()
    card.frame = CGRect(x: 10.25, y: 8.5, width: 140, height: 90)
    card.backgroundColor = color(1, 1, 1)
    card.cornerRadius = 12
    card.borderWidth = 1.5
    card.borderColor = color(0.2, 0.4, 0.9, 0.8)
    card.shadowColor = color(0, 0, 0)
    card.shadowOpacity = 0.35
    card.shadowRadius = 6
    card.shadowOffset = CGSize(width: 0, height: 3)
    root.addSublayer(card)

    let shape = CAShapeLayer()
    shape.contentsScale = scale
    shape.frame = CGRect(x: 170, y: 12, width: 90, height: 90)
    shape.path = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 82, height: 82), transform: nil)
    shape.fillColor = color(0.95, 0.55, 0.15, 0.9)
    shape.strokeColor = color(0.1, 0.1, 0.1)
    shape.lineWidth = 2
    root.addSublayer(shape)

    let rotated = QuietLayer()
    rotated.bounds = CGRect(x: 0, y: 0, width: 80, height: 50)
    rotated.position = CGPoint(x: 80, y: 150)
    rotated.backgroundColor = color(0.3, 0.75, 0.45, 0.85)
    rotated.cornerRadius = 6
    rotated.setAffineTransform(CGAffineTransform(rotationAngle: 15 * .pi / 180))
    root.addSublayer(rotated)

    let clip = QuietLayer()
    clip.frame = CGRect(x: 150, y: 120, width: 150, height: 100)
    clip.masksToBounds = true
    clip.cornerRadius = 18
    clip.backgroundColor = color(0.2, 0.2, 0.25)
    let gradient = CAGradientLayer()
    gradient.frame = CGRect(x: -20, y: -10, width: 200, height: 90)
    gradient.colors = [color(1, 0.3, 0.5), color(0.3, 0.5, 1, 0.6)]
    gradient.startPoint = .zero
    gradient.endPoint = CGPoint(x: 1, y: 1)
    clip.addSublayer(gradient)
    root.addSublayer(clip)

    let masked = QuietLayer()
    masked.frame = CGRect(x: 270, y: 12, width: 40, height: 90)
    masked.backgroundColor = color(0.6, 0.2, 0.8)
    let triangle = CAShapeLayer()
    triangle.contentsScale = scale
    triangle.frame = masked.bounds
    let p = CGMutablePath()
    p.addLines(between: [CGPoint(x: 20, y: 2), CGPoint(x: 38, y: 88), CGPoint(x: 2, y: 88)])
    p.closeSubpath()
    triangle.path = p
    masked.mask = triangle
    root.addSublayer(masked)

    let group = QuietLayer()
    group.frame = CGRect(x: 20, y: 200, width: 120, height: 30)
    group.opacity = 0.5
    group.addSublayer(solid(CGRect(x: 0, y: 0, width: 80, height: 30), color(0.1, 0.1, 0.1)))
    group.addSublayer(solid(CGRect(x: 40.5, y: 5.5, width: 80, height: 20), color(0.9, 0.1, 0.1)))
    root.addSublayer(group)
}

/// The CoreGraphics picture for the cg scene: a gradient background, a translucent rounded panel, lines and text.
func cgSceneContext(scale: CGFloat) -> CGContext {
    let ctx = pointContext(CGSize(width: W, height: H), scale: scale)
    let g = CGGradient(colorsSpace: sRGB, colors: [color(0.98, 0.62, 0.30), color(0.25, 0.30, 0.75, 0.6)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H), options: [])
    drawPanel(ctx, CGRect(x: 20.5, y: 30.25, width: 280, height: 170))
    ctx.setStrokeColor(color(1, 1, 1, 0.8))
    ctx.setLineWidth(0.75)
    for k in 0..<12 {
        ctx.move(to: CGPoint(x: 30 + CGFloat(k) * 22.3, y: 180))
        ctx.addLine(to: CGPoint(x: 40 + CGFloat(k) * 21.1, y: 120 - CGFloat(k % 5) * 9.7))
    }
    ctx.strokePath()
    drawText(ctx, "Deskset 0123456789", x: 34, baseline: 64, size: 22, color: color(1, 1, 1), bold: true)
    drawText(ctx, "The quick brown fox jumps over the lazy dog", x: 34.5, baseline: 90.3, size: 11,
             color: color(0.9, 0.92, 1))
    return ctx
}

// MARK: Rendering

let foundDevice: MTLDevice? = {
    report.setStage("looking for a Metal device")
    let t0 = CACurrentMediaTime()
    let d = MTLCreateSystemDefaultDevice()
    var metal: JSON = ["createSeconds": r(CACurrentMediaTime() - t0, 4),
                       "allDevices": MTLCopyAllDevices().map(describe)]
    if let d { metal["device"] = describe(d) }
    report["metal"] = metal
    report["environment"] = environment()
    return d
}()
if foundDevice == nil {
    print("no Metal device: MTLCreateSystemDefaultDevice() returned nil (\(MTLCopyAllDevices().count) devices listed)")
    finish("no-metal", 4)
}
let device: MTLDevice = foundDevice!
print("Metal device: \(device.name)")
let foundQueue = device.makeCommandQueue()
if foundQueue == nil {
    report["error"] = "makeCommandQueue failed"
    finish("error", 1)
}
let queue: MTLCommandQueue = foundQueue!

/// Bytes that are not a picture, written into a texture before a render.
var garbage: [UInt8] = []

/// A renderer into one sRGB BGRA8 texture of `w` × `h` pixels.
final class Offscreen {
    let w: Int, h: Int
    let texture: MTLTexture
    let renderer: CARenderer

    init(width: Int, height: Int) {
        w = width; h = height
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        texture = device.makeTexture(descriptor: desc)!
        renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: sRGB,
                                                             kCARendererMetalCommandQueue: queue])
        renderer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
    }

    /// Shows `tree` from the next render on. The tree must be committed after it is attached, or nothing is drawn.
    func attach(_ tree: CALayer) {
        renderer.layer = tree
        CATransaction.flush()
    }

    /// Overwrites the texture, so a render that did not touch every pixel shows in the read-back.
    func scribble() {
        let count = w * h * 4
        if garbage.count != count { garbage = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) } }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: garbage, bytesPerRow: w * 4)
    }

    /// Clears the texture to transparent, renders the whole tree and waits until the GPU is done. CARenderer
    /// composites over whatever the texture holds (it does not clear it first, measured), so a comparison must clear
    /// before every render.
    func render() {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let clear = queue.makeCommandBuffer()!
        clear.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
        clear.commit()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let done = queue.makeCommandBuffer()!
        done.commit()
        done.waitUntilCompleted()
    }

    /// The texture's bytes, top row first (the texture's rows are bottom-up).
    func read() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var flipped = [UInt8](repeating: 0, count: bytes.count)
        let row = w * 4
        bytes.withUnsafeBufferPointer { src in
            flipped.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    memcpy(dst.baseAddress! + (h - 1 - y) * row, src.baseAddress! + y * row, row)
                }
            }
        }
        return flipped
    }
}

// MARK: Scenes

/// Everything drawn on the CPU for one scale, and the trees that show it.
struct Sources {
    let scale: CGFloat
    let pw: Int, ph: Int
    let pattern: [UInt8]           // RGBA
    let cgScene: [UInt8]           // RGBA
    let g2Base: [UInt8]            // RGBA: the panel only
    let g2Full: [UInt8]            // RGBA: the panel with every group's elements
    let groupRects: [PixelRect]

    init(scale: CGFloat) {
        self.scale = scale
        pw = Int(W * scale); ph = Int(H * scale)
        pattern = patternBytes(pw, ph)
        cgScene = contextBytes(cgSceneContext(scale: scale))
        let base = pointContext(CGSize(width: W, height: H), scale: scale)
        drawPanel(base, CGRect(x: 0, y: 0, width: W, height: H))
        g2Base = contextBytes(base)
        drawG2Elements(base)
        g2Full = contextBytes(base)
        groupRects = g2Groups.map { PixelRect.of($0, scale: scale) }
    }

    var hashes: JSON {
        ["pattern": sha256(pattern), "cg": sha256(cgScene), "g2Base": sha256(g2Base), "g2Full": sha256(g2Full)]
    }

    func tree(_ scene: String) -> CALayer {
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        return makeTree(scale: scale) { root in
            switch scene {
            case "image":
                root.addSublayer(imageLayer(rgbaImage(pattern, pw, ph), frame: bounds, scale: scale))
            case "solids":
                solidsScene(root, scale: scale)
            case "vector":
                vectorScene(root, scale: scale)
            case "cg":
                root.addSublayer(imageLayer(rgbaImage(cgScene, pw, ph), frame: bounds, scale: scale))
            case "g2-single":
                root.addSublayer(imageLayer(rgbaImage(g2Full, pw, ph), frame: bounds, scale: scale))
            case "g2-tiles", "g2-e":
                let window = PixelRect(x0: 0, y0: 0, x1: pw, y1: ph)
                let base = rgbaImage(g2Base, pw, ph)
                for t in tiles(window, minus: groupRects) {
                    let l = imageLayer(base, frame: t.points(scale), scale: scale)
                    l.contentsRect = CGRect(x: CGFloat(t.x0) / CGFloat(pw), y: CGFloat(t.y0) / CGFloat(ph),
                                            width: CGFloat(t.width) / CGFloat(pw),
                                            height: CGFloat(t.height) / CGFloat(ph))
                    root.addSublayer(l)
                }
                let full = rgbaImage(g2Full, pw, ph)
                for g in groupRects {
                    let crop = full.cropping(to: g.cg)!
                    if scene == "g2-tiles" {
                        root.addSublayer(imageLayer(crop, frame: g.points(scale), scale: scale))
                    } else {
                        let l = PaintLayer()
                        l.anchorPoint = .zero
                        l.contentsScale = scale
                        l.contentsFormat = .RGBA8Uint
                        l.needsDisplayOnBoundsChange = false
                        l.frame = g.points(scale)
                        l.image = crop
                        root.addSublayer(l)
                        l.setNeedsDisplay()
                        l.displayIfNeeded()
                    }
                }
            default:
                fatalError("unknown scene \(scene)")
            }
        }
    }

    /// The layer count of a scene's tree (without the two wrapper layers).
    func layerCount(_ tree: CALayer) -> Int {
        func count(_ l: CALayer) -> Int { 1 + (l.sublayers ?? []).reduce(0) { $0 + count($1) } }
        return count(tree) - 2
    }
}

let sceneNames = ["image", "solids", "vector", "cg", "g2-single", "g2-tiles", "g2-e"]
var scenes: JSON = [:]
var checks: JSON = [:]
var rendered: [String: (bytes: [UInt8], w: Int, h: Int)] = [:]
var sourcesByScale: [CGFloat: Sources] = [:]
var sourceHashes: JSON = [:]
var firstRenderMs: Double?

for scale: CGFloat in [1, 2] {
    let tag = "@\(Int(scale))x"
    report.setStage("drawing the sources at \(Int(scale))x")
    let sources = Sources(scale: scale)
    sourcesByScale[scale] = sources
    sourceHashes[tag] = sources.hashes
    let offscreen = Offscreen(width: sources.pw, height: sources.ph)
    for name in sceneNames {
        report.setStage("rendering \(name)\(tag)")
        let tree = sources.tree(name)
        offscreen.attach(tree)
        offscreen.scribble()
        let t0 = CACurrentMediaTime()
        offscreen.render()
        if firstRenderMs == nil { firstRenderMs = (CACurrentMediaTime() - t0) * 1000 }
        let bytes = offscreen.read()
        // Render once more over garbage: the same bytes, or the render depends on what was in the texture.
        offscreen.scribble()
        offscreen.render()
        let again = offscreen.read()
        let key = name + tag
        rendered[key] = (bytes, sources.pw, sources.ph)
        var s: JSON = ["pixels": "\(sources.pw)x\(sources.ph)", "sha256": sha256(bytes),
                       "layers": sources.layerCount(tree), "sameWhenRenderedAgain": bytes == again,
                       "blank": !bytes.contains { $0 != 0 }]
        if bytes != again { s["renderedAgain"] = diff(bytes, again, width: sources.pw, height: sources.ph) }
        scenes[key] = s
        writePixels(bytes, width: sources.pw, height: sources.ph, name: key)
        print("  \(key): \(s["sha256"]!) (\(s["layers"]!) layers)")
    }
    func check(_ label: String, _ a: [UInt8], _ b: [UInt8]) {
        let d = diff(a, b, width: sources.pw, height: sources.ph)
        checks[label + tag] = d
        print("  check \(label)\(tag): \(summary(d))")
    }
    check("image == its source", rendered["image" + tag]!.bytes, bgra(fromRGBA: sources.pattern))
    check("cg == its source", rendered["cg" + tag]!.bytes, bgra(fromRGBA: sources.cgScene))
    check("g2-single == its source", rendered["g2-single" + tag]!.bytes, bgra(fromRGBA: sources.g2Full))
    check("g2-tiles == g2-single", rendered["g2-tiles" + tag]!.bytes, rendered["g2-single" + tag]!.bytes)
    check("g2-e == g2-single", rendered["g2-e" + tag]!.bytes, rendered["g2-single" + tag]!.bytes)
}
report["scenes"] = scenes
report["checks"] = checks
report["sourceHashes"] = sourceHashes
report["fonts"] = fontNames
report["drawInContexts"] = drawContexts
report["firstRenderMs"] = r(firstRenderMs ?? 0, 2)
report.write()

// MARK: Reference

if let refDir = options.reference {
    report.setStage("comparing with the reference")
    var ref: JSON = ["dir": refDir.lastPathComponent]
    var theirHashes: [String: String] = [:]
    if let data = try? Data(contentsOf: refDir.appendingPathComponent("probe.json")),
       let j = try? JSONSerialization.jsonObject(with: data) as? JSON {
        for (k, v) in j["scenes"] as? JSON ?? [:] { theirHashes[k] = (v as? JSON)?["sha256"] as? String }
        ref["environment"] = j["environment"]
        ref["metalDevice"] = (j["metal"] as? JSON)?["device"].flatMap { ($0 as? JSON)?["name"] }
        if let theirSources = j["sourceHashes"] as? JSON {
            var same: JSON = [:]
            for (tag, mine) in sourceHashes {
                guard let m = mine as? [String: String], let t = theirSources[tag] as? [String: String] else { continue }
                for (k, v) in m { same["\(k)\(tag)"] = t[k] == v }
            }
            ref["sameSources"] = same
        }
    }
    var perScene: JSON = [:]
    var identical = 0
    for key in rendered.keys.sorted() {
        let mine = rendered[key]!
        guard let theirs = readPixels(refDir, name: key) else {
            // The reference may keep only the hash of a scene (the image scenes, which are checked against their
            // source anyway).
            if let h = theirHashes[key] {
                let same = h == sha256(mine.bytes)
                if same { identical += 1 }
                perScene[key] = ["sameHash": same, "pixelsNotKept": true]
                print("  vs reference \(key): \(same ? "identical" : "different") (hash only)")
            } else {
                perScene[key] = ["missing": true]
                print("  vs reference \(key): missing")
            }
            continue
        }
        let d = diff(mine.bytes, theirs, width: mine.w, height: mine.h)
        if (d["differingPixels"] as? Int) == 0 { identical += 1 }
        perScene[key] = d
        print("  vs reference \(key): \(summary(d))")
    }
    ref["scenes"] = perScene
    ref["identicalScenes"] = "\(identical) of \(rendered.count)"
    report["reference"] = ref
    report.write()
}

// MARK: Timing

func stats(_ ms: [Double]) -> JSON {
    let s = ms.sorted()
    func pct(_ p: Double) -> Double { s[min(Int((Double(s.count - 1) * p).rounded()), s.count - 1)] }
    return ["median": r(pct(0.5), 3), "min": r(s.first ?? 0, 3), "max": r(s.last ?? 0, 3), "p90": r(pct(0.9), 3),
            "count": s.count]
}

/// One timed way of rendering; `step` renders once and returns (render ms, read-back ms, bytes).
struct Way {
    let name: String
    let expected: String
    let step: () -> (Double, Double, [UInt8])
}

func ways() -> [Way] {
    var list: [Way] = []
    for scale: CGFloat in [2, 1] {
        let sources = sourcesByScale[scale]!
        let tag = "@\(Int(scale))x"
        let expected = scenes["g2-tiles" + tag].flatMap { ($0 as? JSON)?["sha256"] as? String } ?? ""
        let offscreen = Offscreen(width: sources.pw, height: sources.ph)
        let tree = sources.tree("g2-tiles")
        offscreen.attach(tree)
        // The same tree again: what a pixel gate pays per render once the tree exists.
        list.append(Way(name: "same tree" + tag, expected: expected) {
            offscreen.scribble()
            let t0 = CACurrentMediaTime()
            offscreen.render()
            let t1 = CACurrentMediaTime()
            let bytes = offscreen.read()
            return ((t1 - t0) * 1000, (CACurrentMediaTime() - t1) * 1000, bytes)
        })
        guard scale == 2 else { continue }
        // A new tree each time (layers built, attached, committed, rendered): what each comparison point costs when
        // every tree is built fresh; the bitmaps themselves are drawn once.
        let offscreen2 = Offscreen(width: sources.pw, height: sources.ph)
        list.append(Way(name: "new tree" + tag, expected: expected) {
            offscreen2.scribble()
            let t0 = CACurrentMediaTime()
            offscreen2.attach(sources.tree("g2-tiles"))
            offscreen2.render()
            let t1 = CACurrentMediaTime()
            let bytes = offscreen2.read()
            return ((t1 - t0) * 1000, (CACurrentMediaTime() - t1) * 1000, bytes)
        })
        // A new texture and renderer each time.
        list.append(Way(name: "new renderer" + tag, expected: expected) {
            let t0 = CACurrentMediaTime()
            let o = Offscreen(width: sources.pw, height: sources.ph)
            let created = CACurrentMediaTime() - t0
            o.scribble()   // not timed
            let t1 = CACurrentMediaTime()
            o.attach(sources.tree("g2-tiles"))
            o.render()
            let t2 = CACurrentMediaTime()
            let bytes = o.read()
            return ((created + t2 - t1) * 1000, (CACurrentMediaTime() - t2) * 1000, bytes)
        })
    }
    return list
}

report.setStage("timing")
let timedWays = ways()
var rounds: [JSON] = []
var renderMedians: [String: [Double]] = [:]
var readMedians: [String: [Double]] = [:]
var allStable = true
for round in 1...options.rounds {
    let before = loadAverage()
    var result: JSON = ["loadBefore": before]
    for way in timedWays {
        report.setStage("timing round \(round): \(way.name)")
        var renderMs: [Double] = [], readMs: [Double] = []
        var mismatches = 0
        for _ in 0..<options.renders {
            let (a, b, bytes) = way.step()
            renderMs.append(a)
            readMs.append(b)
            if sha256(bytes) != way.expected { mismatches += 1 }
        }
        if mismatches > 0 { allStable = false }
        let rs = stats(renderMs), bs = stats(readMs)
        renderMedians[way.name, default: []].append(rs["median"] as! Double)
        readMedians[way.name, default: []].append(bs["median"] as! Double)
        result[way.name] = ["renderMs": rs, "readBackMs": bs, "rendersNotMatchingFirstRender": mismatches]
        print("  round \(round) \(way.name): render median \(rs["median"]!) ms (min \(rs["min"]!), max \(rs["max"]!)), "
              + "read-back median \(bs["median"]!) ms, \(mismatches) mismatches")
    }
    let after = loadAverage()
    result["loadAfter"] = after
    result["provisional"] = max(before[0], after[0]) > 8
    rounds.append(result)
}
var timingSummary: JSON = [:]
for way in timedWays {
    let meds = renderMedians[way.name]!, reads = readMedians[way.name]!
    timingSummary[way.name] = [
        "renderMsMedianOfRounds": r(meds.sorted()[meds.count / 2], 3),
        "renderMsRoundMedians": meds,
        "readBackMsMedianOfRounds": r(reads.sorted()[reads.count / 2], 3),
    ]
}
report["timing"] = ["rounds": rounds, "summary": timingSummary, "rendersPerRound": options.renders,
                    "everyRenderMatchedFirstRender": allStable,
                    "tree": "g2-tiles (\(sourcesByScale[2]!.layerCount(sourcesByScale[2]!.tree("g2-tiles"))) layers)"]

// MARK: Summary

print("")
print("SUMMARY")
print("  machine: \(report["environment"].flatMap { ($0 as? JSON)?["model"] } ?? "?"), \(builtArch), "
      + "\(ProcessInfo.processInfo.operatingSystemVersionString)")
print("  Metal device: \(device.name)")
for key in checks.keys.sorted() { print("  \(key): \(summary(checks[key] as! JSON))") }
for key in scenes.keys.sorted() {
    let s = scenes[key] as! JSON
    print("  \(key): sha256 \(s["sha256"]!)\((s["sameWhenRenderedAgain"] as? Bool) == false ? " (NOT stable)" : "")")
}
if let ref = report["reference"] as? JSON { print("  identical to the reference: \(ref["identicalScenes"] ?? "?")") }
for way in timedWays {
    let t = timingSummary[way.name] as! JSON
    print("  \(way.name): render \(t["renderMsMedianOfRounds"]!) ms (round medians \(t["renderMsRoundMedians"]!)), "
          + "read-back \(t["readBackMsMedianOfRounds"]!) ms")
}
finish("ran", 0)
