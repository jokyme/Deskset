#if DEBUG
// A frozen copy of the renderer (see LegacySkinRenderer.swift): the CoreGraphics bridges of the engine's values it
// draws with (made from Support.swift), and where it keeps its caches. Debug builds only.

import AppKit
import DesksetCore
import ObjectiveC

extension RGBA {
    /// `RGBA.cgColor` as it was when the renderer was frozen.
    var legacyCGColor: CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a / 255) }
}

extension SkinRect {
    /// `SkinRect.cgRect` as it was when the renderer was frozen.
    var legacyCGRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Where the frozen copy keeps what it caches on engine objects: beside the live renderer's slots
/// (`Skin.renderContext`, `ShapeMeter.renderCache`), so the two renderers can draw the same skin in one process
/// without taking each other's caches. Released with the object, like those slots.
enum LegacyStorage {
    typealias Key = UnsafeRawPointer

    /// The skin's `LegacySkinRenderContext`.
    static let renderContext = makeKey()
    /// A Shape meter's `LegacyShapeCG.Cache`.
    static let shapeCache = makeKey()

    static func object(on owner: AnyObject, _ key: Key) -> AnyObject? {
        objc_getAssociatedObject(owner, key) as AnyObject?
    }

    static func set(_ value: AnyObject?, on owner: AnyObject, _ key: Key) {
        objc_setAssociatedObject(owner, key, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// A unique address, never freed.
    private static func makeKey() -> Key {
        UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
    }
}
#endif
