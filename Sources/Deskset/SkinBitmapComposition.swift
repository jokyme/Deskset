import AppKit
import Darwin
import DesksetCore
import DesksetDraw

/// An immutable publication. A native composition contains only cropped pixels and glass values, never owner
/// contexts or AppKit views. Contiguous drawing can share a bitmap only until the next native glass boundary.
enum SkinBitmapContent {
    case bitmap(SkinFrame)
    case composition(SkinBitmapComposition)

    var size: CGSize {
        switch self { case .bitmap(let frame): return frame.size; case .composition(let frame): return frame.size }
    }
    var scale: CGFloat {
        switch self { case .bitmap(let frame): return frame.scale; case .composition(let frame): return frame.scale }
    }
}

struct SkinBitmapSlice {
    let image: CGImage
    /// Integer device pixels relative to the viewport, with the first image row at minY.
    let pixelRect: InkBounds.DeviceRect

    func frame(at scale: CGFloat) -> CGRect {
        CGRect(x: CGFloat(pixelRect.minX) / scale, y: CGFloat(pixelRect.minY) / scale,
               width: CGFloat(pixelRect.width) / scale, height: CGFloat(pixelRect.height) / scale)
    }
}

struct SkinBitmapComposition {
    enum Item {
        case pixels(SkinBitmapSlice)
        /// Viewport coordinates, already translated by the captured world's origin.
        case glass(GlassRegion)
    }

    let pixelWidth: Int
    let pixelHeight: Int
    let scale: CGFloat
    let items: [Item]
    let systemGlass: Bool
    /// This publication's scratch allocation plus its independent cropped images. This is not a process,
    /// previously published frame, drawing-cache, Core Animation or WindowServer memory accounting claim.
    let scratchBytes: Int
    let bitmapBytes: Int
    let maximumBitmapBytes: Int

    var size: CGSize { CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale) }

    /// Main checks untrusted/obsolete deliveries before claiming or changing any view. The producer uses the
    /// same checks; no drawing, image conversion or owner resource access takes place here.
    func isValid(for space: CGColorSpace) -> Bool {
        guard space.model == .rgb, scale.isFinite, scale > 0, size.width.isFinite, size.height.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= SkinBitmapComposer.maximumDimension, pixelHeight <= SkinBitmapComposer.maximumDimension,
              maximumBitmapBytes > 0, maximumBitmapBytes <= SkinBitmapComposer.maximumBitmapBytes,
              let rowBytes = SkinBitmapComposer.scratchRowBytes(width: pixelWidth),
              let expectedScratch = SkinBitmapComposer.product(rowBytes, pixelHeight),
              scratchBytes == expectedScratch, scratchBytes <= maximumBitmapBytes else { return false }
        var bytes = 0
        var ids = Set<String>()
        var preceding: [CGRect] = []
        var hasGlass = false
        for item in items {
            switch item {
            case .pixels(let slice):
                let image = slice.image, rect = slice.pixelRect
                guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= pixelWidth, rect.maxY <= pixelHeight,
                      rect.maxX > rect.minX, rect.maxY > rect.minY,
                      rect.width > 0, rect.height > 0, image.width == rect.width, image.height == rect.height,
                      !image.isMask, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
                      image.alphaInfo == .premultipliedFirst,
                      image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
                          == CGBitmapInfo.byteOrder32Little.rawValue,
                      !image.bitmapInfo.contains(.floatComponents),
                      let imageSpace = image.colorSpace, CFEqual(imageSpace, space),
                      let packedRow = SkinBitmapComposer.product(rect.width, 4), image.bytesPerRow == packedRow,
                      let count = SkinBitmapComposer.product(image.bytesPerRow, image.height),
                      count <= maximumBitmapBytes - scratchBytes - bytes else { return false }
                bytes += count
                preceding.append(slice.frame(at: scale))
            case .glass(let region):
                guard SkinBitmapComposer.valid(region), ids.insert(region.id).inserted else { return false }
                hasGlass = true
                let rect = SkinBitmapComposer.visibleRect(region, size: size)
                if !systemGlass, !rect.isNull, preceding.contains(where: { $0.intersects(rect) }) { return false }
                if !rect.isNull { preceding.append(rect) }
            }
        }
        return hasGlass && bitmapBytes == bytes
    }
}

/// Owner-only raster preparation. The one full-viewport scratch is reused for all content segments; retained
/// images own just their copied ink rows. Ideal geometry candidates cannot establish a safe text/shape crop.
enum SkinBitmapComposer {
    static let maximumBitmapBytes = 16 * 1024 * 1024
    static let maximumDimension = 16384

    enum Failure: Error, Equatable {
        case invalidDestination, invalidGlass, nestedGlass, bitmapBudgetExceeded, allocationFailed
        case qualificationFailed, unsupportedFallbackOverlap
    }

    static func needsComposition(_ scene: WidgetScene) -> Bool {
        scene.elements.contains { $0.visibility == .visible && $0.backing == .native(.glass) }
    }

    static func make(_ capture: SkinBitmapDrawing.Capture, scale: CGFloat, space: CGColorSpace,
                     systemGlass: Bool, maximumBitmapBytes requestedBudget: Int = SkinBitmapComposer.maximumBitmapBytes,
                     beforeDrawing: ((CGContext) -> Bool)? = nil) throws -> SkinBitmapComposition {
        let size = capture.size, origin = capture.origin
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              scale.isFinite, scale > 0, origin.x.isFinite, origin.y.isFinite else { throw Failure.invalidDestination }
        let pw = ceil(size.width * scale), ph = ceil(size.height * scale)
        guard pw.isFinite, ph.isFinite, pw > 0, ph > 0,
              pw <= CGFloat(maximumDimension), ph <= CGFloat(maximumDimension) else { throw Failure.invalidDestination }
        let width = Int(pw), height = Int(ph), budget = min(requestedBudget, maximumBitmapBytes)
        guard budget > 0, let rowBytes = scratchRowBytes(width: width),
              let scratchBytes = product(rowBytes, height), scratchBytes <= budget else { throw Failure.bitmapBudgetExceeded }
        // Supplying an explicit stride bounds the allocation before Core Graphics is called.
        guard let scratch = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: rowBytes, space: space, bitmapInfo: bitmapInfo), scratch.bytesPerRow == rowBytes,
              let raw = scratch.data else { throw Failure.allocationFailed }
        if let beforeDrawing {
            scratch.saveGState()
            scratch.translateBy(x: 0, y: CGFloat(height)); scratch.scaleBy(x: scale, y: -scale)
            scratch.translateBy(x: -origin.x, y: -origin.y)
            let ready = beforeDrawing(scratch)
            scratch.restoreGState()
            guard ready else { throw Failure.qualificationFailed }
        }
        let viewport = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        var items: [SkinBitmapComposition.Item] = []
        var pending: [DrawItem] = []
        var retainedBytes = 0
        var preceding: [CGRect] = []
        var ids = Set<String>()

        func flush() throws {
            guard !pending.isEmpty else { return }
            scratch.clear(CGRect(x: 0, y: 0, width: width, height: height))
            SkinBitmapDrawing.draw(items: 0..<1, [pending], context: capture.context, cycle: capture.cycle,
                                   into: scratch, height: height, scale: scale, origin: origin)
            pending.removeAll(keepingCapacity: true)
            guard let rect = alphaBounds(raw, width: width, height: height, rowBytes: rowBytes) else { return }
            guard let packedRow = product(rect.width, 4), let count = product(packedRow, rect.height),
                  count <= budget - scratchBytes - retainedBytes else { throw Failure.bitmapBudgetExceeded }
            // A CGImage crop can retain the complete parent image. Copy into an independently owned provider,
            // and never make a snapshot of the scratch (which could force a full-viewport copy on the next draw).
            guard let data = malloc(count) else { throw Failure.allocationFailed }
            for row in 0..<rect.height {
                memcpy(data.advanced(by: row * packedRow),
                       raw.advanced(by: (rect.minY + row) * rowBytes + rect.minX * 4), packedRow)
            }
            guard let provider = CGDataProvider(dataInfo: nil, data: data, size: count, releaseData: { _, data, _ in
                free(UnsafeMutableRawPointer(mutating: data))
            }) else { free(data); throw Failure.allocationFailed }
            guard let image = CGImage(width: rect.width, height: rect.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: packedRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw Failure.allocationFailed
            }
            let slice = SkinBitmapSlice(image: image, pixelRect: rect)
            items.append(.pixels(slice)); preceding.append(slice.frame(at: scale))
            retainedBytes += count
        }

        for item in capture.scene.drawingItems {
            if case .glass(let source) = item {
                try flush()
                let region = translated(source, by: origin)
                guard valid(region), ids.insert(region.id).inserted else { throw Failure.invalidGlass }
                let rect = visibleRect(region, size: viewport)
                // Behind-window material cannot sample earlier same-window pixels. Within-window material is
                // also not a general fallback: Apple forbids overlapping effect views. Accept only disjoint
                // desktop-backdrop islands here; bounding rectangles intentionally reject some safe gaps.
                if !systemGlass, !rect.isNull, preceding.contains(where: { $0.intersects(rect) }) {
                    throw Failure.unsupportedFallbackOverlap
                }
                items.append(.glass(region))
                if !rect.isNull { preceding.append(rect) }
                // Preserve the existing near-transparent window hit area above this native piece.
                pending.append(item)
            } else {
                guard !containsGlass(item) else { throw Failure.nestedGlass }
                pending.append(item)
            }
        }
        try flush()
        let result = SkinBitmapComposition(pixelWidth: width, pixelHeight: height, scale: scale, items: items,
            systemGlass: systemGlass, scratchBytes: scratchBytes, bitmapBytes: retainedBytes, maximumBitmapBytes: budget)
        guard result.isValid(for: space) else { throw Failure.invalidGlass }
        return result
    }

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    fileprivate static func product(_ a: Int, _ b: Int) -> Int? {
        guard a >= 0, b >= 0 else { return nil }
        let result = a.multipliedReportingOverflow(by: b)
        return result.overflow ? nil : result.partialValue
    }

    fileprivate static func scratchRowBytes(width: Int) -> Int? {
        guard let packed = product(width, 4), packed <= Int.max - 63 else { return nil }
        return ((packed + 63) / 64) * 64
    }

    private static func alphaBounds(_ raw: UnsafeMutableRawPointer, width: Int, height: Int,
                                    rowBytes: Int) -> InkBounds.DeviceRect? {
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width where bytes[y * rowBytes + x * 4 + 3] != 0 {
                minX = min(minX, x); maxX = max(maxX, x + 1)
                minY = min(minY, y); maxY = max(maxY, y + 1)
            }
        }
        return InkBounds.DeviceRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private static func containsGlass(_ item: DrawItem) -> Bool {
        switch item {
        case .glass: return true
        case .transformed(_, let items), .antialias(_, let items): return items.contains(where: containsGlass)
        case .container(_, let mask, let content): return mask.contains(where: containsGlass) || content.contains(where: containsGlass)
        default: return false
        }
    }

    fileprivate static func valid(_ region: GlassRegion) -> Bool {
        func validRect(_ rect: SkinRect) -> Bool {
            rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite
                && rect.maxX.isFinite && rect.maxY.isFinite && rect.width > 0 && rect.height > 0
        }
        guard !region.id.isEmpty, validRect(region.rect), region.cornerRadius.isFinite, region.cornerRadius >= 0,
              region.cornerRadius <= min(region.rect.width, region.rect.height) / 2,
              region.clip.map(validRect) ?? true else { return false }
        if let tint = region.tint {
            return [tint.r, tint.g, tint.b, tint.a].allSatisfy { $0.isFinite && (0...255).contains($0) }
        }
        return true
    }

    fileprivate static func visibleRect(_ region: GlassRegion, size: CGSize) -> CGRect {
        var rect = region.rect.cgRect.intersection(CGRect(origin: .zero, size: size))
        if let clip = region.clip { rect = rect.intersection(clip.cgRect) }
        return rect.isEmpty ? .null : rect
    }

    private static func translated(_ source: GlassRegion, by origin: SkinPoint) -> GlassRegion {
        var region = source
        region.rect.x -= origin.x; region.rect.y -= origin.y
        if var clip = region.clip { clip.x -= origin.x; clip.y -= origin.y; region.clip = clip }
        return region
    }
}
