import CoreGraphics
import Foundation
import ImageIO
import DesksetCore

/// Prepares immutable SVG snapshots on the drawing owner. Resource decoding never reads files or URLs.
package enum SVGRenderer {
    fileprivate indirect enum Node {
        case group(CGAffineTransform, Double, CGPath?, [Node], CGRect, CGRect)
        case path(SVGPathDraw, CGPath, CGPath?, CGRect)
        case image(CGImage, CGRect, SVGPreserveAspectRatio)

        var objectBounds: CGRect {
            switch self {
            case .group(let transform, _, _, _, _, let bounds): return bounds.applying(transform)
            case .path(_, let path, _, _): return path.boundingBoxOfPath
            case .image(_, let rect, _): return rect
            }
        }

        var bounds: CGRect {
            switch self {
            case .group(let transform, _, let clip, _, let bounds, _):
                return (clip.map { bounds.intersection($0.boundingBoxOfPath) } ?? bounds).applying(transform)
            case .path(_, _, _, let bounds): return bounds
            case .image(_, let rect, _): return rect
            }
        }
    }

    package final class Cache {
        private struct Entry {
            let revision: Int
            let nodes: [Node]
            let bytes: Int
            var lastUse: UInt64
        }

        private var entries: [UUID: Entry] = [:]
        private var clock: UInt64 = 0
        private var bytes = 0
        package private(set) var builds = 0
        package private(set) var imageDecodes = 0
        package var count: Int { entries.count }
        package static let maxSources = 256
        package static let maxDecodedBytes = 64 * 1024 * 1024

        fileprivate func prepared(_ draw: SVGDraw) -> [Node] {
            clock &+= 1
            if var cached = entries[draw.sourceID], cached.revision == draw.revision {
                cached.lastUse = clock
                entries[draw.sourceID] = cached
                return cached.nodes
            }
            if let old = entries.removeValue(forKey: draw.sourceID) { bytes -= old.bytes }
            builds += 1
            var decodedBytes = 0
            var images: [Data: CGImage] = [:]
            let nodes = draw.nodes.compactMap { prepare($0, decodedBytes: &decodedBytes, images: &images) }
            while !entries.isEmpty && (entries.count >= Self.maxSources || bytes + decodedBytes > Self.maxDecodedBytes) {
                guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
                bytes -= oldest.value.bytes
                entries.removeValue(forKey: oldest.key)
            }
            if decodedBytes <= Self.maxDecodedBytes {
                entries[draw.sourceID] = Entry(revision: draw.revision, nodes: nodes, bytes: decodedBytes, lastUse: clock)
                bytes += decodedBytes
            }
            return nodes
        }

        private func prepare(_ input: SVGRenderNode, decodedBytes: inout Int, images: inout [Data: CGImage]) -> Node? {
            switch input {
            case .group(let transform, let opacity, let clip, let children):
                let nodes = children.compactMap { prepare($0, decodedBytes: &decodedBytes, images: &images) }
                let bounds = nodes.reduce(CGRect.null) { $0.union($1.bounds) }
                let objectBounds = nodes.reduce(CGRect.null) { $0.union($1.objectBounds) }
                return .group(ShapeCG.cgTransform(transform), unit(opacity),
                              clip.map { clipRegion($0, objectBounds: objectBounds) }, nodes, bounds, objectBounds)
            case .path(let item):
                let path = ShapeCG.cgPath(item.path.subpaths)
                var stroke: CGPath?
                if item.strokeStyle.width.isFinite, item.strokeStyle.width > 0, item.stroke != .none {
                    let style = item.strokeStyle
                    let dashed = style.dashes.isEmpty ? path : path.copy(dashingWithPhase: style.dashOffset * style.width,
                        lengths: style.dashes.map { $0 * style.width })
                    stroke = dashed.copy(strokingWithWidth: style.width, lineCap: ShapeCG.cgCap(style.startCap),
                                         lineJoin: ShapeCG.cgJoin(style.join), miterLimit: style.miterLimit)
                }
                let bounds = path.boundingBoxOfPath.union(stroke?.boundingBoxOfPath ?? .null)
                return .path(item, path, stroke, bounds)
            case .image(let item):
                if let image = images[item.data] { return .image(image, rectangle(item.rect), item.preserveAspectRatio) }
                guard let image = decode(item.data, remainingBytes: Self.maxDecodedBytes - decodedBytes) else { return nil }
                imageDecodes += 1
                decodedBytes += image.bytesPerRow * image.height
                images[item.data] = image
                return .image(image, rectangle(item.rect), item.preserveAspectRatio)
            }
        }
    }

    package static func geometryBounds(_ draw: SVGDraw, context: DrawContext) -> CGRect {
        let bounds = context.svg.prepared(draw).reduce(CGRect.null) { $0.union($1.bounds) }
        return bounds.isNull ? .null : bounds.offsetBy(dx: draw.contentFrame.x, dy: draw.contentFrame.y)
    }

    package static func draw(_ draw: SVGDraw, in canvas: CGContext, context: DrawContext) {
        let nodes = context.svg.prepared(draw)
        canvas.saveGState()
        canvas.translateBy(x: draw.contentFrame.x, y: draw.contentFrame.y)
        canvas.setAllowsAntialiasing(true)
        canvas.setShouldAntialias(true)
        // Capture inherited alpha once; individual fill/stroke alpha belongs inside the SVG composition.
        canvas.beginTransparencyLayer(auxiliaryInfo: nil)
        for node in nodes { paint(node, in: canvas) }
        canvas.endTransparencyLayer()
        canvas.restoreGState()
    }

    private static func paint(_ node: Node, in canvas: CGContext) {
        canvas.saveGState()
        defer { canvas.restoreGState() }
        switch node {
        case .group(let transform, let opacity, let clip, let children, _, _):
            guard opacity > 0, transform.determinant.isFinite, abs(transform.determinant) > 1e-15 else { return }
            canvas.concatenate(transform)
            if let clip {
                // Quartz leaves the current clip unchanged for an empty current path. A resolved empty SVG
                // clipping region instead hides the entire group (for example, disjoint nested clips).
                guard !clip.isEmpty else { return }
                canvas.addPath(clip)
                canvas.clip()
            }
            canvas.setAlpha(opacity)
            canvas.beginTransparencyLayer(auxiliaryInfo: nil)
            for child in children { paint(child, in: canvas) }
            canvas.endTransparencyLayer()
        case .path(let item, let path, let stroke, _):
            let bounds = path.boundingBoxOfPath
            paint(item.fill, opacity: item.fillOpacity, path: path,
                  rule: item.path.fillRule == .evenOdd ? .evenOdd : .winding, objectBounds: bounds, in: canvas)
            if let stroke {
                paint(item.stroke, opacity: item.strokeOpacity, path: stroke, rule: .winding, objectBounds: bounds, in: canvas)
            }
        case .image(let image, let viewport, let ratio):
            guard viewport.width > 0, viewport.height > 0 else { return }
            var target = viewport
            if !ratio.none {
                let sx = viewport.width / CGFloat(image.width), sy = viewport.height / CGFloat(image.height)
                let scale = ratio.slice ? max(sx, sy) : min(sx, sy)
                target.size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                target.origin.x += (viewport.width - target.width) * ratio.x.rawValue
                target.origin.y += (viewport.height - target.height) * ratio.y.rawValue
            }
            canvas.clip(to: viewport)
            // SVG coordinates are y-down. CGImage's scanline origin needs exactly one local flip.
            canvas.translateBy(x: target.minX, y: target.maxY)
            canvas.scaleBy(x: 1, y: -1)
            canvas.draw(image, in: CGRect(origin: .zero, size: target.size))
        }
    }

    private static func paint(_ paint: SVGPaint, opacity: Double, path: CGPath, rule: CGPathFillRule,
                              objectBounds: CGRect, in canvas: CGContext) {
        guard opacity > 0 else { return }
        if paint == .none { return }
        canvas.saveGState()
        defer { canvas.restoreGState() }
        canvas.setAlpha(unit(opacity))
        canvas.addPath(path)
        switch paint {
        case .none: return
        case .color(let color): canvas.setFillColor(color.cgColor); canvas.fillPath(using: rule)
        case .gradient(let gradient):
            canvas.clip(using: rule)
            drawGradient(gradient, bounds: objectBounds, in: canvas)
        }
    }

    /// Each clip child is a region under its own fill rule, not another subpath in one even-odd path.
    private static func clipRegion(_ clip: SVGClip, objectBounds: CGRect) -> CGPath {
        var region = CGPath(rect: .zero, transform: nil)
        for child in clip.children { region = region.union(clipChild(child).region, using: .winding) }
        var transform = ShapeCG.cgTransform(clip.transform)
        if clip.units == .objectBoundingBox {
            guard usable(objectBounds), objectBounds.width > 0, objectBounds.height > 0 else {
                return CGPath(rect: .zero, transform: nil)
            }
            transform = transform.concatenating(CGAffineTransform(a: objectBounds.width, b: 0, c: 0,
                d: objectBounds.height, tx: objectBounds.minX, ty: objectBounds.minY))
        }
        return region.copy(using: &transform) ?? region
    }

    private struct ClipShape {
        var region: CGPath
        /// Clipping changes the silhouette, never the geometry used by a later objectBoundingBox clip.
        var objectBounds: CGRect
    }

    private static func clipChild(_ node: SVGClipNode) -> ClipShape {
        switch node {
        case .path(let item):
            let path = ShapeCG.cgPath(item.subpaths)
            return ClipShape(region: path.normalized(using: item.fillRule == .evenOdd ? .evenOdd : .winding),
                             objectBounds: path.boundingBoxOfPath)
        case .group(let transform, let clip, let children):
            var region = CGPath(rect: .zero, transform: nil)
            var bounds = CGRect.null
            for child in children {
                let shape = clipChild(child)
                region = region.union(shape.region, using: .winding)
                bounds = bounds.union(shape.objectBounds)
            }
            if let clip { region = region.intersection(clipRegion(clip, objectBounds: bounds), using: .winding) }
            var matrix = ShapeCG.cgTransform(transform)
            return ClipShape(region: region.copy(using: &matrix) ?? region, objectBounds: bounds.applying(matrix))
        }
    }

    private static func decode(_ data: Data, remainingBytes: Int) -> CGImage? {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { return nil }
        let png = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        let jpeg = data.starts(with: [255, 216, 255])
        guard png || jpeg,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, type == "public.png" || type == "public.jpeg",
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width <= 16_777_216 / height else { return nil }
        // Account for 16-bit PNG channels before asking ImageIO to allocate decompressed pixels.
        let depth = (props[kCGImagePropertyDepth] as? Int) ?? 8
        guard depth > 0, depth <= 16, remainingBytes > 0 else { return nil }
        let bytesPerPixel = depth > 8 ? 8 : 4
        guard width <= remainingBytes / height / bytesPerPixel,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldAllowFloat: false] as CFDictionary),
              image.bytesPerRow <= remainingBytes / image.height else { return nil }
        return image
    }

    private final class GradientFunction {
        let gradient: SVGGradient
        let lower: Double
        let upper: Double
        init(_ gradient: SVGGradient, lower: Double, upper: Double) {
            self.gradient = gradient
            self.lower = lower
            self.upper = upper
        }

        func color(_ position: Double) -> RGBA {
            let value = lower + position * (upper - lower)
            let t: Double
            switch gradient.spread {
            case .pad: t = unit(value)
            case .repeat: t = value - floor(value)
            case .reflect:
                let remainder = value - floor(value / 2) * 2
                t = remainder <= 1 ? remainder : 2 - remainder
            }
            let stops = gradient.stops
            guard let first = stops.first, let last = stops.last else { return .init(r: 0, g: 0, b: 0, a: 0) }
            if t < first.position { return first.color }
            if t >= last.position { return last.color }
            for index in 1..<stops.count where stops[index].position > t {
                let a = stops[index - 1], b = stops[index]
                let mix = unit((t - a.position) / (b.position - a.position))
                return RGBA(r: a.color.r + (b.color.r - a.color.r) * mix,
                            g: a.color.g + (b.color.g - a.color.g) * mix,
                            b: a.color.b + (b.color.b - a.color.b) * mix,
                            a: a.color.a + (b.color.a - a.color.a) * mix)
            }
            return last.color
        }

        func make() -> CGFunction? {
            let info = Unmanaged.passRetained(self).toOpaque()
            var callbacks = CGFunctionCallbacks(version: 0, evaluate: { info, input, output in
                guard let info else { return }
                let color = Unmanaged<GradientFunction>.fromOpaque(info).takeUnretainedValue().color(input[0])
                output[0] = unit(color.r / 255); output[1] = unit(color.g / 255)
                output[2] = unit(color.b / 255); output[3] = unit(color.a / 255)
            }, releaseInfo: { info in
                if let info { Unmanaged<GradientFunction>.fromOpaque(info).release() }
            })
            let function = CGFunction(info: info, domainDimension: 1, domain: [0, 1], rangeDimension: 4,
                                      range: [0, 1, 0, 1, 0, 1, 0, 1], callbacks: &callbacks)
            if function == nil { Unmanaged<GradientFunction>.fromOpaque(info).release() }
            return function
        }
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func drawGradient(_ gradient: SVGGradient, bounds: CGRect, in canvas: CGContext) {
        guard let endColor = gradient.stops.last?.color else { return }
        func solid() { canvas.setFillColor(endColor.cgColor); canvas.fill(canvas.boundingBoxOfClipPath) }
        var transform = ShapeCG.cgTransform(gradient.transform)
        if gradient.units == .objectBoundingBox {
            guard usable(bounds), bounds.width > 0, bounds.height > 0 else { return }
            transform = transform.concatenating(CGAffineTransform(a: bounds.width, b: 0, c: 0, d: bounds.height,
                tx: bounds.minX, ty: bounds.minY))
        }
        guard transform.determinant.isFinite, abs(transform.determinant) > 1e-15 else { solid(); return }
        canvas.saveGState()
        defer { canvas.restoreGState() }
        canvas.concatenate(transform)
        let clip = canvas.boundingBoxOfClipPath
        guard usable(clip) else { return }
        let corners = [CGPoint(x: clip.minX, y: clip.minY), CGPoint(x: clip.maxX, y: clip.minY),
                       CGPoint(x: clip.minX, y: clip.maxY), CGPoint(x: clip.maxX, y: clip.maxY)]
        let shading: CGShading?
        switch gradient.kind {
        case .linear(let start, let end):
            let dx = end.x - start.x, dy = end.y - start.y, lengthSquared = dx * dx + dy * dy
            guard lengthSquared.isFinite, lengthSquared > 1e-24 else { solid(); return }
            let positions = corners.map { (($0.x - start.x) * dx + ($0.y - start.y) * dy) / lengthSquared }
            let lower = gradient.spread == .pad ? 0 : positions.min() ?? 0
            let upper = gradient.spread == .pad ? 1 : positions.max() ?? 1
            guard lower.isFinite, upper.isFinite, upper > lower else { solid(); return }
            guard let function = GradientFunction(gradient, lower: lower, upper: upper).make() else { return }
            shading = CGShading(axialSpace: colorSpace,
                start: CGPoint(x: start.x + lower * dx, y: start.y + lower * dy),
                end: CGPoint(x: start.x + upper * dx, y: start.y + upper * dy),
                function: function, extendStart: true, extendEnd: true)
        case .radial(let center, let inputFocus, let radius):
            guard radius.isFinite, radius > 1e-12 else { solid(); return }
            var focus = inputFocus
            let distance = hypot(focus.x - center.x, focus.y - center.y)
            if distance >= radius {
                let ratio = radius * (1 - 1e-7) / distance
                focus = ShapePoint(center.x + (focus.x - center.x) * ratio,
                                   center.y + (focus.y - center.y) * ratio)
            }
            let dx = center.x - focus.x, dy = center.y - focus.y
            let a = radius * radius - dx * dx - dy * dy
            let upper = gradient.spread == .pad ? 1 : max(1, corners.map { point -> Double in
                let qx = point.x - focus.x, qy = point.y - focus.y
                let q2 = qx * qx + qy * qy, dot = qx * dx + qy * dy
                let root = sqrt(max(0, dot * dot + a * q2))
                return dot >= 0 ? q2 / max(1e-300, root + dot) : (root - dot) / max(1e-300, a)
            }.max() ?? 1)
            guard upper.isFinite, let function = GradientFunction(gradient, lower: 0, upper: upper).make() else { return }
            shading = CGShading(radialSpace: colorSpace, start: ShapeCG.cg(focus), startRadius: 0,
                end: CGPoint(x: focus.x + dx * upper, y: focus.y + dy * upper), endRadius: radius * upper,
                function: function, extendStart: true, extendEnd: true)
        }
        if let shading { canvas.drawShading(shading) }
    }

    private static func rectangle(_ rect: SkinRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
    }

    private static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}

private extension CGAffineTransform {
    var determinant: CGFloat { a * d - b * c }
}
