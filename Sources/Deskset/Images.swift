import DesksetCore
import DesksetDraw

typealias Images = DesksetDraw.Images

// The app's skin hosts answer the optional image queries of the engine (EXIF orientation, pixel alpha).

extension RenderHost: SkinImageQueries {
    func imageExifOrientation(atPath path: String) -> Int { Images.exifOrientation(atPath: path) }
    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        Images.pixelAlpha(atPath: path, x: x, y: y, oriented: exifOriented)
    }
}
