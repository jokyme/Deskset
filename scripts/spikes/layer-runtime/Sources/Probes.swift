// `probes`: small checks behind two statements in results.md about how memory is measured.
//
//   1. Describing a CGContext (CFCopyDescription) costs microseconds and leaks memory on every call (the spike's
//      context log did this on every draw in its first runs).
//   2. phys_footprint counts only pages mapped into the process: a CGImage made from a bitmap context keeps the
//      context's pages by copy-on-write and is charged again only when something in the process reads it.
import CoreGraphics
import Foundation
import QuartzCore

func probes() -> JSON {
    let mb = 1024.0 * 1024.0
    var j: JSON = ["memoryPressure": memoryPressure()]

    // 1. CFCopyDescription on a bitmap context, 100,000 times (each in its own autorelease pool).
    do {
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: bgraInfo)!
        let n = 100_000
        let f0 = physFootprint()
        let t0 = CACurrentMediaTime()
        for _ in 0..<n {
            autoreleasepool {
                let d = CFCopyDescription(ctx) as String
                _ = d.count
            }
        }
        let t1 = CACurrentMediaTime()
        let f1 = physFootprint()
        // The same for a color space's description, as a control.
        for _ in 0..<n {
            autoreleasepool {
                let d = CFCopyDescription(ctx.colorSpace!) as String
                _ = d.count
            }
        }
        let f2 = physFootprint()
        j["describeContext"] = ["calls": n, "microsecondsPerCall": r((t1 - t0) / Double(n) * 1e6, 2),
                                "footprintIncreaseMB": r((f1 - f0) / mb, 2),
                                "bytesPerCall": r((f1 - f0) / Double(n), 0),
                                "controlColorSpaceFootprintIncreaseMB": r((f2 - f1) / mb, 2)]
    }

    // 2. Eight 1600 × 1600 px images, each drawn (random pixels, so nothing compresses) into its own bitmap context,
    // turned into a CGImage with makeImage, the context released. Then CoreGraphics draws each image once into a
    // small context, which reads all its pixels.
    do {
        let w = 1600, h = 1600
        func image(_ seed: UInt64) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                bitmapInfo: bgraInfo)!
            let p = ctx.data!.assumingMemoryBound(to: UInt64.self)
            var x = seed
            for i in 0..<(ctx.bytesPerRow * h / 8) {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17
                p[i] = x | 0xFF00_0000_FF00_0000
            }
            return ctx.makeImage()!
        }
        let f0 = physFootprint()
        var images: [CGImage] = []
        for i in 0..<8 { autoreleasepool { images.append(image(0x9E37_79B9_7F4A_7C15 &+ UInt64(i) * 7919)) } }
        let f1 = physFootprint()
        let small = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: bgraInfo)!
        for im in images { autoreleasepool { small.draw(im, in: CGRect(x: 0, y: 0, width: 64, height: 64)) } }
        let f2 = physFootprint()
        // A live context of the same size with a uniform fill, kept: charged in full.
        let live = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                             bitmapInfo: bgraInfo)!
        live.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 0.9))
        live.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let f3 = physFootprint()
        Thread.sleep(forTimeInterval: 3)
        let f4 = physFootprint()
        j["imagesFromReleasedContexts"] = [
            "images": images.count, "bytesEachMB": r(Double(w * h * 4) / mb, 2),
            "footprintIncreaseAfterMakingMB": r((f1 - f0) / mb, 2),
            "footprintIncreaseAfterCoreGraphicsReadThemMB": r((f2 - f1) / mb, 2),
            "liveUniformContextMB": r((f3 - f2) / mb, 2),
            "liveUniformContextAfter3sMB": r((f4 - f2) / mb, 2),
        ]
        _ = live.data
    }
    return j
}
