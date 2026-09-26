import AppKit
import ImageIO
import DesksetCore
import UniformTypeIdentifiers

/// The app side of FileView's `Type=Icon` child measures (`FileViewIcons.writer` in DesksetCore): the Finder icon of
/// a file or folder (NSWorkspace), rendered at the pixel size the measure asks for and written to its `IconPath`.
///
/// Manual (FileView plugin): the icon is saved as an .ico file (default `icon<Index>.ico` in the skin folder) that an
/// Image meter shows. Here the file is a real Windows icon file (ImageIO's ICO encoder) when the path ends in .ico
/// and the size fits the format (≤ 256 pixels); otherwise, or when the encoder is missing, PNG data is written
/// whatever the extension — ImageIO recognises either from the content, so the Image meter loads both.
/// Called on FileView's background queue: nothing here touches the main thread, and the file is replaced atomically
/// (an Image meter drawing meanwhile sees the old or the new icon, never half a file).
enum FileViewIconWriter {
    /// Installs the writer (at startup, for the app and the command-line modes).
    static func install() {
        FileViewIcons.writer = { source, size, destination in
            write(source: source, pixelSize: size, destination: destination)
        }
    }

    /// Largest icon rendered (FileView asks for 16, 32, 48 or 256).
    static let maxPixelSize = 1024

    /// Serialises the AppKit part. FileView's queue is concurrent (several Icon children write at once), and
    /// NSWorkspace may hand out one shared NSImage for common icons (folders, generic documents): an NSImage must not
    /// be drawn on two threads at the same time.
    private static let renderLock = NSLock()

    /// Renders and writes the icon; false when nothing could be written.
    static func write(source: String, pixelSize: Int, destination: String) -> Bool {
        guard !source.isEmpty, !destination.isEmpty else { return false }
        let side = min(max(pixelSize, 1), maxPixelSize)
        let rendered: CGImage? = {
            renderLock.lock()
            defer { renderLock.unlock() }
            return render(NSWorkspace.shared.icon(forFile: source), side: side)
        }()
        guard let image = rendered,
              let data = encode(image, pathExtension: (destination as NSString).pathExtension) else { return false }
        let url = URL(fileURLWithPath: destination)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The icon drawn into a `side`×`side` bitmap (NSImage picks the representation made for that pixel size).
    static func render(_ icon: NSImage, side: Int) -> CGImage? {
        guard side > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Whether ImageIO can write Windows icon files on this system.
    static let canWriteICO: Bool = {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains("com.microsoft.ico")
    }()

    /// ICO for `.ico` paths (when possible), PNG otherwise.
    static func encode(_ image: CGImage, pathExtension: String) -> Data? {
        let ico = pathExtension.lowercased() == "ico" && canWriteICO && image.width <= 256 && image.height <= 256
        if ico, let data = encode(image, type: "com.microsoft.ico") { return data }
        return encode(image, type: UTType.png.identifier)
    }

    private static func encode(_ image: CGImage, type: String) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }
}
