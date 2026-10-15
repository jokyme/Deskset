import CoreGraphics
import DesksetCore

extension RGBA {
    /// The corresponding sRGB color without a platform UI color object.
    var cgColor: CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a / 255) }
}

extension SkinRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
