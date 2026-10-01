import CoreFoundation
import CoreGraphics
import DesksetCore
import DesksetDraw

/// One owner-confined bitmap. No context or data pointer escapes; snapshots may outlive this mutable owner.
package final class Rasterizer {
    package enum Failure: Error, Equatable {
        case invalidInput(String)
        case invalidPlan(String)
        case resourceLimit(String)
        case resourceFailure(String)
        case incompatibleColorSpace
        case invalidMapping
    }

    package static let maximumDimension = 16_384
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    package let storageByteCount: Int
    private let bitmap: CGContext
    private let colorSpace: CGColorSpace
    private var drawing = false

    package static func requiredBytes(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else { throw Failure.invalidInput("Bitmap dimensions must be positive") }
        let (row, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (bytes, imageOverflow) = row.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !imageOverflow, width <= maximumDimension, height <= maximumDimension else {
            throw Failure.resourceLimit("Bitmap dimensions exceed representable or supported limits")
        }
        return bytes
    }

    package init(width: Int, height: Int, colorSpace: CGColorSpace, maximumBitmapBytes: Int) throws {
        guard maximumBitmapBytes > 0 else { throw Failure.invalidInput("Bitmap budget must be positive") }
        let bytes = try Self.requiredBytes(width: width, height: height)
        guard bytes <= maximumBitmapBytes else { throw Failure.resourceLimit("Bitmap exceeds its byte budget") }
        guard colorSpace.model == .rgb else { throw Failure.incompatibleColorSpace }
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: colorSpace, bitmapInfo: Self.bitmapInfo),
              bitmap.data != nil else { throw Failure.resourceFailure("Cannot allocate the owned bitmap") }
        guard let actualSpace = bitmap.colorSpace, CFEqual(actualSpace, colorSpace) else {
            throw Failure.incompatibleColorSpace
        }
        let (actualBytes, overflow) = bitmap.bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, actualBytes <= maximumBitmapBytes else {
            throw Failure.resourceLimit("Actual bitmap row storage exceeds its byte budget")
        }
        guard bitmap.bitsPerComponent == 8, bitmap.bitsPerPixel == 32,
              bitmap.alphaInfo == .premultipliedFirst,
              bitmap.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder32Little.rawValue else {
            throw Failure.resourceFailure("The owned bitmap does not have the requested BGRA8 format")
        }
        self.bitmap = bitmap
        self.colorSpace = colorSpace
        storageByteCount = actualBytes
    }

    /// `rect` is a canonical top-row device rectangle. A supplied crop is copied in raw bitmap space before
    /// applying the scene mapping; it must already have this bitmap's exact size, format and actual profile.
    package func image(of items: [DrawItem], in rect: InkBounds.DeviceRect, scale: CGFloat, baseCrop: CGImage?,
                       context: DrawContext, cycle: Int, glass: GlassPaint) throws -> CGImage {
        guard !drawing else { throw Failure.invalidInput("Rasterization is not reentrant") }
        guard scale.isFinite, scale > 0, rect.width == bitmap.width, rect.height == bitmap.height,
              rect.minX >= 0, rect.minY >= 0, rect.maxX <= Self.maximumDimension, rect.maxY <= Self.maximumDimension else {
            throw Failure.invalidInput("Bitmap size and canonical device rectangle do not agree")
        }
        if let baseCrop { try validate(baseCrop) }
        drawing = true
        defer { drawing = false }
        bitmap.saveGState()
        defer { bitmap.restoreGState() }
        let local = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
        bitmap.clear(local)
        if let baseCrop {
            bitmap.saveGState()
            bitmap.setBlendMode(.copy)
            bitmap.interpolationQuality = .none
            bitmap.draw(baseCrop, in: local)
            bitmap.restoreGState()
        }
        // Equivalent to H1's flip/scale/translation, without dividing an integer device origin by scale first.
        // The raw bitmap maps user y-up to memory rows; this produces userToDevice = (s,0,0,s,-x,-y).
        bitmap.concatenate(CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                             tx: -CGFloat(rect.minX), ty: CGFloat(rect.maxY)))
        let target = DrawTarget.prepareOwnedBitmap(bitmap, glass: glass)
        let expected = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                         tx: -CGFloat(rect.minX), ty: -CGFloat(rect.minY))
        guard target.userToDevice == expected else { throw Failure.invalidMapping }
        guard let actualSpace = target.colorSpace, CFEqual(actualSpace, colorSpace) else {
            throw Failure.incompatibleColorSpace
        }
        DrawExecutor.draw(items, in: bitmap, context: context, cycle: cycle, target: target)
        guard let image = bitmap.makeImage() else { throw Failure.resourceFailure("Cannot snapshot the owned bitmap") }
        try validate(image)
        return image
    }

    private func validate(_ image: CGImage) throws {
        guard image.width == bitmap.width, image.height == bitmap.height,
              image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .premultipliedFirst,
              image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder32Little.rawValue else {
            throw Failure.invalidInput("Image does not match the owned bitmap's size and BGRA8 format")
        }
        guard let space = image.colorSpace, CFEqual(space, colorSpace) else { throw Failure.incompatibleColorSpace }
    }
}
