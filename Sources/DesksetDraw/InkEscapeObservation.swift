import CoreFoundation
import CoreGraphics

/// Alpha observed in one explicit snapshot, not a proof that native ink is absent outside its finite canvas.
/// The caller supplies the snapshot's canonical device rectangle and foreground-only recipe provenance.
package enum InkEscapeObservation {
    package enum Failure: Error, Equatable {
        case invalidInput(String)
        case resourceLimit(String)
        case unsupportedImage
        case incompatibleColorSpace
        case unavailablePixels
    }

    package struct Pixel: Equatable, Sendable {
        package let column: Int
        package let row: Int
        package let globalX: Int
        package let globalY: Int
        package let alpha: UInt8
    }

    package enum Outside: Equatable, Sendable {
        case counted(pixels: Int, first: Pixel?)
        case unknown(InkBounds.Unknown)
    }

    package struct Observation: Equatable, Sendable {
        package let canvas: InkBounds.DeviceRect
        package let candidate: InkBounds.Candidate
        package let alphaPixels: Int
        package let firstAlpha: Pixel?
        package let outside: Outside
        package let edgePixels: Int
        package let firstEdge: Pixel?
    }

    /// Reads explicit BGRA8 premultipliedFirst/32Little bytes without drawing or returning their owner.
    /// colorSpace is the caller's actual space; mismatches never substitute a profile.
    /// The public provider getter may copy CFData. These are layout/data budgets, not a process peak limit.
    package static func scan(_ image: CGImage, in canvas: InkBounds.DeviceRect,
                             candidate: InkBounds.Candidate, colorSpace: CGColorSpace,
                             maximumPixels: Int, maximumBytes: Int) throws -> Observation {
        guard !canvas.isEmpty, maximumPixels > 0, maximumBytes > 0 else {
            throw Failure.invalidInput("Canvas dimensions and observation budgets must be positive")
        }
        let width = canvas.width, height = canvas.height
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (activeRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !rowOverflow else {
            throw Failure.resourceLimit("Canvas pixel or active-row size overflows")
        }
        guard pixels <= maximumPixels, activeRow <= maximumBytes else {
            throw Failure.resourceLimit("Canvas exceeds its explicit observation budget")
        }
        guard image.width == width, image.height == height else {
            throw Failure.invalidInput("Snapshot dimensions do not match its declared canvas")
        }
        guard !image.isMask, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.alphaInfo == .premultipliedFirst,
              image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
                  == CGBitmapInfo.byteOrder32Little.rawValue,
              !image.bitmapInfo.contains(.floatComponents) else {
            throw Failure.unsupportedImage
        }
        guard colorSpace.model == .rgb, let actualSpace = image.colorSpace, CFEqual(actualSpace, colorSpace) else {
            throw Failure.incompatibleColorSpace
        }
        let stride = image.bytesPerRow
        let (storageBytes, storageOverflow) = stride.multipliedReportingOverflow(by: height)
        guard stride >= activeRow else {
            throw Failure.unsupportedImage
        }
        guard !storageOverflow, storageBytes <= maximumBytes else {
            throw Failure.resourceLimit("Snapshot row storage exceeds its explicit observation budget")
        }
        guard let data = image.dataProvider?.data else {
            throw Failure.unavailablePixels
        }
        let length = CFDataGetLength(data)
        guard length >= storageBytes else {
            throw Failure.unavailablePixels
        }
        guard length <= maximumBytes else {
            throw Failure.resourceLimit("Provider data exceeds its explicit observation budget")
        }
        guard let bytes = CFDataGetBytePtr(data) else {
            throw Failure.unavailablePixels
        }

        return try withExtendedLifetime(data) {
            var visible = 0, escaped = 0, edge = 0
            var firstAlpha: Pixel?, firstEscape: Pixel?, firstEdge: Pixel?
            for row in 0..<height {
                let (rowOffset, offsetOverflow) = row.multipliedReportingOverflow(by: stride)
                let (globalY, yOverflow) = canvas.minY.addingReportingOverflow(row)
                guard !offsetOverflow, !yOverflow else {
                    throw Failure.resourceLimit("Pixel row address or coordinate overflows")
                }
                for column in 0..<width {
                    let (columnOffset, columnOverflow) = column.multipliedReportingOverflow(by: 4)
                    let (alphaOffset, alphaOverflow) = columnOffset.addingReportingOverflow(3)
                    let (offset, addressOverflow) = rowOffset.addingReportingOverflow(alphaOffset)
                    guard !columnOverflow, !alphaOverflow, !addressOverflow,
                          offset >= 0, offset < storageBytes else {
                        throw Failure.resourceLimit("Pixel alpha address overflows its row storage")
                    }
                    let alpha = bytes[offset]
                    guard alpha > 0 else { continue }
                    let (globalX, xOverflow) = canvas.minX.addingReportingOverflow(column)
                    guard !xOverflow else {
                        throw Failure.resourceLimit("Pixel column coordinate overflows")
                    }
                    let pixel = Pixel(column: column, row: row, globalX: globalX, globalY: globalY, alpha: alpha)
                    // Every count is a subset of the checked width*height, so incrementing cannot overflow.
                    visible += 1
                    if firstAlpha == nil { firstAlpha = pixel }
                    if column == 0 || row == 0 || column == width - 1 || row == height - 1 {
                        edge += 1
                        if firstEdge == nil { firstEdge = pixel }
                    }
                    let outside: Bool
                    switch candidate {
                    case .empty: outside = true
                    case let .rectangle(rect): outside = !rect.contains(x: globalX, y: globalY)
                    // Unknown has no outside comparison; alpha and edge observations still remain valid.
                    case .unknown: outside = false
                    }
                    if outside {
                        escaped += 1
                        if firstEscape == nil { firstEscape = pixel }
                    }
                }
            }
            let outside: Outside
            if case let .unknown(reason) = candidate {
                outside = .unknown(reason)
            } else {
                outside = .counted(pixels: escaped, first: firstEscape)
            }
            return Observation(canvas: canvas, candidate: candidate, alphaPixels: visible, firstAlpha: firstAlpha,
                               outside: outside, edgePixels: edge, firstEdge: firstEdge)
        }
    }
}
