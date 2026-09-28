import AppKit
import DesksetCore

/// The look thumbnails of the widget page: the real widget drawn in each look, small. Each is an instance of the
/// widget loaded from the editing session's text with the look variable set to that look (in its file, in memory
/// only), updated once and drawn with glass stand-ins over a soft backdrop. Made when asked (`render`); a changed
/// widget asks again.
final class StudioLookThumbnails {
    private var images: [String: NSImage] = [:]
    /// What the images were made from (the text of the files, the look, the appearance): made again when it changes.
    private var madeFrom = ""

    func image(look: String) -> NSImage? { images[look.lowercased()] }

    var isEmpty: Bool { images.isEmpty }

    func clear() {
        images = [:]
        madeFrom = ""
    }

    /// The tile's size in points.
    static let tile = NSSize(width: 64, height: 42)

    /// Draws the widget in each of `look`'s looks (nothing when they are already drawn from the same text).
    func render(session: EditingSession, look: StudioWidgetFacts.Look, skinsDirectory: URL) {
        guard let studio = session.studioSkin, let file = look.file else { return }
        let key = ([studio.fileURL] + studio.includedFiles).map { url -> String in
            session.buffers.buffer(url).map { "\($0.text.hashValue)" } ?? url.path
        }.joined(separator: "|") + "|\(look.current)|\(String(describing: session.host.appearance?.isDark))"
        guard key != madeFrom else { return }
        madeFrom = key
        images = [:]
        for value in look.values {
            let provider = LookSourceProvider(base: session.buffers, file: file, variable: look.variable, value: value)
            let host = StudioHost()
            host.appearance = session.host.appearance
            let skin = Skin(config: session.config, fileURL: studio.fileURL, skinsDirectory: skinsDirectory,
                            system: SystemMonitor.shared, host: host)
            skin.sourceProvider = provider
            skin.actionPolicy = host.policy
            skin.measureValues = session.measureValues
            do { try skin.load() } catch { continue }
            skin.update()
            if let image = Self.draw(skin, dark: session.host.appearance?.isDark ?? false) {
                images[value.lowercased()] = image
            }
            skin.close()
        }
    }

    /// The widget, fitted into a tile over a soft backdrop.
    static func draw(_ skin: Skin, dark: Bool) -> NSImage? {
        let scale: CGFloat = 2
        let size = tile
        let w = max(skin.width, 1), h = max(skin.height, 1)
        let fit = min((size.width - 6) / w, (size.height - 6) / h)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        // A soft backdrop like a wallpaper, so glass and light text show.
        let colors = dark ? [NSColor(srgbRed: 0.24, green: 0.16, blue: 0.36, alpha: 1),
                             NSColor(srgbRed: 0.12, green: 0.14, blue: 0.30, alpha: 1)]
            : [NSColor(srgbRed: 0.93, green: 0.62, blue: 0.70, alpha: 1),
               NSColor(srgbRed: 0.66, green: 0.62, blue: 0.93, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: NSRect(origin: .zero, size: size), angle: -20)
        // The widget, flipped into the tile's middle.
        cg.saveGState()
        cg.translateBy(x: (size.width - w * fit) / 2, y: (size.height + h * fit) / 2)
        cg.scaleBy(x: fit, y: -fit)
        SkinRenderer.draw(skin, in: cg, glass: .placeholder(dark: dark))
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

/// The editing session's text, with one `[Variables]` entry of one file set to another value.
final class LookSourceProvider: SourceProvider {
    let base: SourceBuffers
    let file: SourceFileID
    let variable: String
    let value: String

    init(base: SourceBuffers, file: URL, variable: String, value: String) {
        self.base = base
        self.file = SourceFileID(file)
        self.variable = variable
        self.value = value
    }

    func sourceText(for url: URL) -> String? {
        let text = base.sourceText(for: url)
        guard SourceFileID(url) == file else { return text }
        let original = text ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return (try? IniWriter.updating(original, value: value, key: variable, section: "Variables")) ?? original
    }
}
