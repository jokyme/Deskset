// Reading back our own windows, pixel buffers, comparisons and small PNG crops.
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: Window capture

typealias CreateWindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
typealias CreateImageFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

/// CGWindowListCreateImage and CGWindowListCreateImageFromArray, looked up at run time: the macOS 15 SDK made them
/// unavailable to new code, but they still read back this process's own windows when screen capture is allowed.
/// The spike only checks the permission (CGPreflightScreenCaptureAccess), it never asks for it.
let createWindowImage: CreateWindowImage? = dlsym(rtldDefault, "CGWindowListCreateImage")
    .map { unsafeBitCast($0, to: CreateWindowImage.self) }
let createImageFromArray: CreateImageFromArray? = dlsym(rtldDefault, "CGWindowListCreateImageFromArray")
    .map { unsafeBitCast($0, to: CreateImageFromArray.self) }

var canCapture: Bool { CGPreflightScreenCaptureAccess() && createWindowImage != nil }

// kCGWindowListOptionIncludingWindow = 1 << 3
// kCGWindowImageBoundsIgnoreFraming = 1 << 0, kCGWindowImageBestResolution = 1 << 3
private let imageOptions: UInt32 = 1 << 0 | 1 << 3

/// One of our windows alone, at the display's resolution, with its alpha (what the window server made of its layers).
func captureWindow(_ window: NSWindow) -> CGImage? {
    createWindowImage?(.null, 1 << 3, UInt32(window.windowNumber), imageOptions)?.takeRetainedValue()
}

/// Several of our windows composited together by the window server, in their on-screen order.
func captureWindows(_ windows: [NSWindow], bounds: CGRect = .null) -> CGImage? {
    var pointers: [UnsafeRawPointer?] = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
    guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil) else { return nil }
    return createImageFromArray?(bounds, array, imageOptions)?.takeRetainedValue()
}

/// A description of an image's pixel format.
func describe(_ image: CGImage) -> JSON {
    [
        "width": image.width, "height": image.height, "bitsPerComponent": image.bitsPerComponent,
        "bitsPerPixel": image.bitsPerPixel, "bitmapInfo": String(image.bitmapInfo.rawValue, radix: 16),
        "colorSpace": colorSpaceName(image.colorSpace),
    ]
}

func colorSpaceName(_ space: CGColorSpace?) -> String {
    guard let space else { return "none" }
    if let name = space.name as String? { return name }
    return NSColorSpace(cgColorSpace: space)?.localizedName ?? "unnamed (model \(space.model.rawValue))"
}

// MARK: Pixels

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// 8-bit, 4-channel premultiplied pixels (BGRA or RGBA, as the source had them), rows top-down.
struct Pixels {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    subscript(x: Int, y: Int, c: Int) -> UInt8 { bytes[(y * width + x) * 4 + c] }
    func alpha(_ x: Int, _ y: Int, bgra: Bool = true) -> UInt8 { self[x, y, 3] }

    /// The raw bytes of an 8-bit, 32-bit-per-pixel image, without any conversion (nil for other formats).
    static func raw(_ image: CGImage) -> Pixels? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let w = image.width, h = image.height, rowBytes = image.bytesPerRow
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                memcpy(dst.baseAddress! + y * w * 4, base + y * rowBytes, w * 4)
            }
        }
        return Pixels(width: w, height: h, bytes: bytes)
    }

    /// The image drawn into an 8-bit premultiplied BGRA bitmap in `space` (a conversion when the image is in
    /// another space or format).
    static func drawn(_ image: CGImage, in space: CGColorSpace) -> Pixels {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: space, bitmapInfo: bgraInfo)!
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Pixels(width: w, height: h, bytes: bytes)
    }

    /// Pixels in the same layout as `raw` gives for BGRA captures (the window server's format here).
    static func of(_ image: CGImage) -> Pixels {
        if image.bitmapInfo.rawValue == bgraInfo, let p = raw(image) { return p }
        return drawn(image, in: image.colorSpace ?? sRGB)
    }

    func image(space: CGColorSpace) -> CGImage {
        var copy = bytes
        return copy.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space, bitmapInfo: bgraInfo)!
            return ctx.makeImage()!
        }
    }

    func crop(_ rect: CGRect) -> Pixels {
        let x0 = max(0, Int(rect.minX)), y0 = max(0, Int(rect.minY))
        let x1 = min(width, Int(rect.maxX)), y1 = min(height, Int(rect.maxY))
        let w = max(0, x1 - x0), h = max(0, y1 - y0)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w * 4 { out[y * w * 4 + x] = bytes[((y0 + y) * width + x0) * 4 + x] }
        }
        return Pixels(width: w, height: h, bytes: out)
    }

    var nonTransparentCount: Int {
        var n = 0
        for i in stride(from: 3, to: bytes.count, by: 4) where bytes[i] != 0 { n += 1 }
        return n
    }
}

/// premultipliedFirst | byteOrder32Little: BGRA in memory, the window server's and IOSurface's order.
let bgraInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

// MARK: Comparison

struct Diff {
    var maxChannel = 0
    var differing = 0
    var total = 0
    /// Differing pixels by their largest channel difference: 1, 2, 3, 4–7, 8+.
    var histogram = [0, 0, 0, 0, 0]
    var bounds: CGRect = .null
    var sizeMismatch = false

    var ratio: Double { total > 0 ? Double(differing) / Double(total) : 0 }

    var json: JSON {
        var j: JSON = ["maxChannelDiff": maxChannel, "differingPixels": differing, "pixels": total,
                       "differingPercent": r(ratio * 100, 3),
                       "byMaxDiff": ["1": histogram[0], "2": histogram[1], "3": histogram[2], "4-7": histogram[3],
                                     "8+": histogram[4]]]
        if sizeMismatch { j["sizeMismatch"] = true }
        if !bounds.isNull {
            j["differingBounds"] = [Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height)]
        }
        return j
    }
}

/// Compares two pixel buffers channel by channel. `include(x, y)` limits the pixels compared.
func compare(_ a: Pixels, _ b: Pixels, include: ((Int, Int) -> Bool)? = nil) -> Diff {
    var d = Diff()
    guard a.width == b.width, a.height == b.height else {
        d.sizeMismatch = true
        return d
    }
    a.bytes.withUnsafeBufferPointer { pa in
        b.bytes.withUnsafeBufferPointer { pb in
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<a.height {
                for x in 0..<a.width {
                    if let include, !include(x, y) { continue }
                    d.total += 1
                    let o = (y * a.width + x) * 4
                    var m = 0
                    for c in 0..<4 { m = max(m, abs(Int(pa[o + c]) - Int(pb[o + c]))) }
                    guard m > 0 else { continue }
                    d.differing += 1
                    d.maxChannel = max(d.maxChannel, m)
                    d.histogram[m == 1 ? 0 : m == 2 ? 1 : m == 3 ? 2 : m < 8 ? 3 : 4] += 1
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            if maxX >= 0 { d.bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) }
        }
    }
    return d
}

/// A picture of where two buffers differ: the first image in gray, differing pixels in red (brighter = larger).
func diffImage(_ a: Pixels, _ b: Pixels) -> CGImage? {
    guard a.width == b.width, a.height == b.height else { return nil }
    var out = Pixels(width: a.width, height: a.height, bytes: [UInt8](repeating: 0, count: a.bytes.count))
    for i in stride(from: 0, to: a.bytes.count, by: 4) {
        var m = 0
        for c in 0..<4 { m = max(m, abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c]))) }
        if m == 0 {
            // Gray version of `a` over white (unpremultiplied look is not needed: this is only a map).
            let alpha = Int(a.bytes[i + 3])
            let gray = (Int(a.bytes[i]) + Int(a.bytes[i + 1]) + Int(a.bytes[i + 2])) / 3
            let v = UInt8(min(255, 255 - alpha + gray) / 2 + 64)
            out.bytes[i] = v; out.bytes[i + 1] = v; out.bytes[i + 2] = v; out.bytes[i + 3] = 255
        } else {
            out.bytes[i] = 0; out.bytes[i + 1] = 0; out.bytes[i + 2] = UInt8(min(255, 120 + m * 60))
            out.bytes[i + 3] = 255
        }
    }
    return out.image(space: sRGB)
}

// MARK: PNG

@discardableResult
func writePNG(_ image: CGImage, _ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

/// Nearest-neighbour enlargement (for crops of a few pixels).
func enlarged(_ image: CGImage, _ factor: Int) -> CGImage? {
    let w = image.width * factor, h = image.height * factor
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: image.colorSpace ?? sRGB, bitmapInfo: bgraInfo) else { return nil }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}
