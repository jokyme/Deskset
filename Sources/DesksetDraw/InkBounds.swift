import CoreGraphics
import DesksetCore

/// Geometry candidates for the future layer partitioner. A candidate is not a guarantee about raster coverage:
/// native glyphs, hinting and inherited graphics state require an independent ink-escape check before partitioning.
public enum InkBounds {
    public enum Unknown: String, Equatable, Sendable {
        case invalidGeometry, invalidMapping, unresolvedRasterization
    }

    /// Half-open integer edges in the destination's device coordinates, including its captured origin and y direction.
    /// Construction rejects dimensions that cannot be represented, so callers can safely read width and height.
    public struct DeviceRect: Equatable, Sendable {
        public let minX: Int
        public let minY: Int
        public let maxX: Int
        public let maxY: Int

        public init?(minX: Int, minY: Int, maxX: Int, maxY: Int) {
            let width = maxX.subtractingReportingOverflow(minX)
            let height = maxY.subtractingReportingOverflow(minY)
            guard !width.overflow, !height.overflow, width.partialValue >= 0, height.partialValue >= 0 else {
                return nil
            }
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }

        public var width: Int { maxX - minX }
        public var height: Int { maxY - minY }
        public var isEmpty: Bool { width == 0 || height == 0 }

        public func contains(x: Int, y: Int) -> Bool {
            x >= minX && x < maxX && y >= minY && y < maxY
        }
    }

    public enum Candidate: Equatable, Sendable {
        case empty
        case rectangle(DeviceRect)
        case unknown(Unknown)
    }

    /// Ideal user-space geometry only. Unknown native rasterization is kept separate from a genuinely empty recipe.
    package enum Geometry {
        case empty
        case bounds(CGRect)
        case unknown(Unknown)
    }

    /// Supplies an outward-rounded candidate. Padding is expressed in device pixels, independent of user-space
    /// scale or shear. A nonempty result still needs a raster-escape check; padding does not establish that guarantee.
    public static func candidate(of item: DrawItem, context: DrawContext, target: DrawTarget,
                                 padding: Int = 0) -> Candidate {
        switch InkGeometry.of(item, context: context, target: target) {
        case .empty: return .empty
        case let .unknown(reason): return .unknown(reason)
        case let .bounds(rect):
            guard let covered = deviceRectangle(covering: rect, target: target, padding: padding) else {
                return .unknown(.invalidMapping)
            }
            return covered.isEmpty ? .empty : .rectangle(covered)
        }
    }

    /// Maps all four corners through the actual destination mapping and rounds the enclosing rectangle outward.
    /// Negative dimensions are standardized. Empty rectangles remain empty rather than acquiring ink from padding.
    /// Invalid, singular, overflowing or unrepresentable mappings are rejected instead of being treated as empty.
    public static func deviceRectangle(covering rect: CGRect, target: DrawTarget,
                                       padding: Int = 0) -> DeviceRect? {
        let t = target.userToDevice
        guard padding >= 0, [t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy(\.isFinite),
              [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite),
              rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
        let determinant = t.a * t.d - t.b * t.c
        guard determinant.isFinite, determinant != 0 else { return nil }
        let r = rect.standardized
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].map { $0.applying(t) }
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let x0 = corners.map(\.x).min(), let x1 = corners.map(\.x).max(),
              let y0 = corners.map(\.y).min(), let y1 = corners.map(\.y).max(),
              let minX = Int(exactly: x0.rounded(.down)), let minY = Int(exactly: y0.rounded(.down)) else { return nil }
        if r.isEmpty { return DeviceRect(minX: minX, minY: minY, maxX: minX, maxY: minY) }
        guard let maxX = Int(exactly: x1.rounded(.up)), let maxY = Int(exactly: y1.rounded(.up)) else { return nil }
        let left = minX.subtractingReportingOverflow(padding), top = minY.subtractingReportingOverflow(padding)
        let right = maxX.addingReportingOverflow(padding), bottom = maxY.addingReportingOverflow(padding)
        guard !left.overflow, !top.overflow, !right.overflow, !bottom.overflow else { return nil }
        return DeviceRect(minX: left.partialValue, minY: top.partialValue,
                          maxX: right.partialValue, maxY: bottom.partialValue)
    }
}
