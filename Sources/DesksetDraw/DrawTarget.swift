import CoreGraphics

/// The current mapping from drawing points to device pixels. Each caller keeps its existing scale limits.
public struct DrawTarget {
    public let userToDevice: CGAffineTransform

    public init(userToDevice: CGAffineTransform) {
        self.userToDevice = userToDevice
    }

    /// Length of the transformed horizontal unit vector, used by image-mask composites.
    public var horizontalPixelsPerPoint: CGFloat {
        hypot(userToDevice.a, userToDevice.b)
    }

    /// Larger of the two transformed unit-vector lengths, used by image decoding and symbol rasterization.
    public var maximumPixelsPerPoint: CGFloat {
        max(horizontalPixelsPerPoint, hypot(userToDevice.c, userToDevice.d))
    }
}
