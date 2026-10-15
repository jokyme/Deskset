import CoreGraphics
import DesksetCore

/// One owner's native measurement and raster cache. The budget counts retained CGImage row storage; it does
/// not describe AppKit's internal symbol resources or WindowServer memory. Preflight pins all images needed
/// by a frame, so eviction cannot turn an accepted frame into a partially drawn one.
package final class IconCache {
    package static let maximumBitmapBytes = 16 << 20
    package static let maximumDimension = 16384
    private static let maximumMeasurements = 1024

    private struct RequestKey: Hashable {
        let request: IconRequest
        init(_ request: IconRequest) { self.request = request }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.request == rhs.request }
        func hash(into hasher: inout Hasher) {
            hasher.combine(request.name); hasher.combine(request.style); hasher.combine(request.colors.rawValue)
            hasher.combine(request.appearance.name); hasher.combine(request.appearance.value.isDark)
            hasher.combine(request.scale)
        }
    }
    private struct MeasurementKey: Hashable { let request: RequestKey; let generation: Int }
    private struct Measurement { let size: SkinSize?; var used: UInt64 }
    private struct RasterIdentity: Hashable { let request: RequestKey; let width: Int; let height: Int }
    private struct RasterKey: Hashable { let identity: RasterIdentity; let generation: Int }
    private struct Raster {
        let image: CGImage
        let naturalSize: SkinSize
        let bytes: Int
        var used: UInt64
    }

    private let fonts: any FontResolving
    private let rasterizer: (any IconRasterizing)?
    private let budget: Int
    private var measurements: [MeasurementKey: Measurement] = [:]
    private var rasters: [RasterKey: Raster] = [:]
    private var pinned: [RasterIdentity: RasterKey] = [:]
    private var clock: UInt64 = 0
    package private(set) var bitmapBytes = 0
    package private(set) var measureBuilds = 0
    package private(set) var rasterBuilds = 0
    package var rasterCount: Int { rasters.count }
    package var fontGeneration: Int { fonts.generation }

    package init(fonts: any FontResolving, rasterizer: (any IconRasterizing)?,
                 maximumBitmapBytes: Int = IconCache.maximumBitmapBytes) {
        precondition(maximumBitmapBytes > 0 && maximumBitmapBytes <= Self.maximumBitmapBytes)
        self.fonts = fonts; self.rasterizer = rasterizer; budget = maximumBitmapBytes
    }

    package func measure(_ request: IconRequest) throws -> SkinSize? {
        try validate(request)
        guard !request.name.isEmpty else { return nil }
        if let folder = request.style.fontFolder { fonts.registerFolder(folder) }
        let key = MeasurementKey(request: RequestKey(request), generation: fonts.generation)
        guard let rasterizer else { throw IconDrawingError.unavailableRasterizer }
        let font = fonts.resolve(FontRequest(style: request.style))
        clock &+= 1
        if var hit = measurements[key], rasterizer.isPrepared(request, font: font, fontGeneration: key.generation) {
            hit.used = clock; measurements[key] = hit
            return hit.size
        }
        let size = try rasterizer.measure(request, font: font, fontGeneration: key.generation)
        if let size, !Self.valid(size) { throw IconDrawingError.invalidGeometry }
        measureBuilds += 1
        if measurements.count >= Self.maximumMeasurements,
           let oldest = measurements.min(by: { $0.value.used < $1.value.used }) { measurements.removeValue(forKey: oldest.key) }
        measurements[key] = Measurement(size: size, used: clock)
        return size
    }

    /// Called once before qualifying the complete frame, under its actual destination transform.
    package func beginFrame() { pinned.removeAll(keepingCapacity: true) }
    package func cancelFrame() { pinned.removeAll(keepingCapacity: true) }

    package func prepare(_ draw: IconDraw, in ctx: CGContext, pin: Bool = false) throws -> CGImage? {
        let identity = try rasterIdentity(draw, in: ctx)
        guard let identity else { return nil }
        // A qualified frame uses the exact resources it accepted, even if the font service changes afterward.
        if !pin, let key = pinned[identity], let hit = rasters[key] {
            guard hit.naturalSize == draw.naturalSize else { throw IconDrawingError.naturalSizeChanged }
            return hit.image
        }
        guard let size = try measure(draw.request) else { return nil }
        guard size == draw.naturalSize else { throw IconDrawingError.naturalSizeChanged }
        let key = RasterKey(identity: identity, generation: fonts.generation)
        clock &+= 1
        if var hit = rasters[key] {
            hit.used = clock; rasters[key] = hit
            if pin { pinned[identity] = key }
            return hit.image
        }
        guard let rasterizer else { throw IconDrawingError.unavailableRasterizer }
        let row = identity.width.multipliedReportingOverflow(by: 4)
        let count = row.partialValue.multipliedReportingOverflow(by: identity.height)
        guard !row.overflow, !count.overflow, count.partialValue <= budget else { throw IconDrawingError.bitmapBudget }
        try reserve(count.partialValue)
        let raster = try rasterizer.rasterize(draw.request, font: fonts.resolve(FontRequest(style: draw.request.style)),
                                              fontGeneration: key.generation, naturalSize: size,
                                              pixelWidth: identity.width, pixelHeight: identity.height)
        let image = raster.image
        let actual = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard image.width == identity.width, image.height == identity.height,
              image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.bytesPerRow >= row.partialValue,
              !actual.overflow, actual.partialValue <= budget,
              raster.pointSize.width == size.width, raster.pointSize.height == size.height else {
            throw IconDrawingError.rasterization
        }
        try reserve(actual.partialValue)
        rasterBuilds += 1
        rasters[key] = Raster(image: image, naturalSize: size, bytes: actual.partialValue, used: clock)
        bitmapBytes += actual.partialValue
        if pin { pinned[identity] = key }
        return image
    }

    private func reserve(_ bytes: Int) throws {
        let protected = Set(pinned.values)
        // Bound historical tiny bitmaps without limiting how many distinct icons a valid current frame uses.
        while rasters.count >= Self.maximumMeasurements,
              let oldest = rasters.filter({ !protected.contains($0.key) }).min(by: { $0.value.used < $1.value.used }) {
            bitmapBytes -= oldest.value.bytes
            rasters.removeValue(forKey: oldest.key)
        }
        while bitmapBytes > budget - bytes {
            guard let oldest = rasters.filter({ !protected.contains($0.key) }).min(by: { $0.value.used < $1.value.used }) else {
                throw IconDrawingError.bitmapBudget
            }
            bitmapBytes -= oldest.value.bytes
            rasters.removeValue(forKey: oldest.key)
        }
    }

    private func rasterIdentity(_ draw: IconDraw, in ctx: CGContext) throws -> RasterIdentity? {
        try validate(draw.request)
        let rect = draw.contentFrame
        guard [rect.x, rect.y, rect.width, rect.height, rect.x + rect.width, rect.y + rect.height].allSatisfy(\.isFinite),
              rect.width >= 0, rect.height >= 0, Self.valid(draw.naturalSize) else { throw IconDrawingError.invalidGeometry }
        guard rect.width > 0, rect.height > 0 else { return nil }
        let transform = ctx.userSpaceToDeviceSpaceTransform
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite) else {
            throw IconDrawingError.invalidGeometry
        }
        let horizontal = hypot(transform.a, transform.b) * rect.width / draw.naturalSize.width
        let vertical = hypot(transform.c, transform.d) * rect.height / draw.naturalSize.height
        let density = (max(horizontal, vertical) * 8).rounded(.up) / 8
        guard density.isFinite, density > 0 else { throw IconDrawingError.invalidGeometry }
        let width = (draw.naturalSize.width * density).rounded(.up)
        let height = (draw.naturalSize.height * density).rounded(.up)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= Double(Self.maximumDimension), height <= Double(Self.maximumDimension) else {
            throw IconDrawingError.bitmapBudget
        }
        return RasterIdentity(request: RequestKey(draw.request), width: Int(width), height: Int(height))
    }

    private func validate(_ request: IconRequest) throws {
        let points = TextStyle.pixelSize(points: request.style.fontSize)
        guard points.isFinite, points > 0, points <= Double(Self.maximumDimension) else { throw IconDrawingError.invalidFont }
        guard request.scale.isFinite, request.scale > 0, request.scale <= Double(Self.maximumDimension) else {
            throw IconDrawingError.invalidGeometry
        }
        let color = request.style.color
        guard [color.r, color.g, color.b, color.a].allSatisfy(\.isFinite) else { throw IconDrawingError.invalidGeometry }
    }

    private static func valid(_ size: SkinSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

package enum IconRenderer {
    package static func draw(_ draw: IconDraw, in ctx: CGContext, cache: IconCache) {
        // Desk destinations preflight the whole frame first. Standalone replay retains the usual renderer API.
        guard let image = try? cache.prepare(draw, in: ctx) else { return }
        ImageRenderer.drawCGImage(image, in: draw.contentFrame.cgRect, ctx)
    }
}
