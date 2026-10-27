import AppKit
import DesksetCore
import ImageIO

/// The cursor for a `MouseActionCursorName` value (manual, Mouse actions: "several built-in Windows cursors may be used
/// without needing any file name or extension. HAND, TEXT, HELP, BUSY, CROSS, PEN, NO, SIZE_ALL, SIZE_NESW, SIZE_NS,
/// SIZE_NWSE, SIZE_WE, UPARROW, WAIT", or a `.cur` / `.ani` file in the skin's `@Resources\Cursors`).
///
/// - macOS cursors where there is one: HAND, TEXT, CROSS, NO, SIZE_WE, SIZE_NS, and SIZE_NWSE / SIZE_NESW on macOS 15
///   and later (the frame-resize cursors).
/// - The others are drawn from SF Symbols in the style of the system cursors (black, white outline): HELP and BUSY are
///   the arrow with a question mark or an hourglass, WAIT an hourglass, PEN a pencil, UPARROW an up arrow, SIZE_ALL a
///   four-way arrow, and the diagonal sizes before macOS 15. BUSY and WAIT do not spin.
/// - Files: the image closest to 32 points (Windows' standard cursor size) with its hot spot; an `.ani` shows its first
///   frame. A name that is neither a built-in cursor nor a readable file shows the hand, the standard pointer for
///   mouse actions (judgment call).
/// Used on the main thread only.
enum SkinCursors {
    static func cursor(named name: String?, cursorsDirectory: URL?) -> NSCursor {
        guard let raw = name?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return .arrow }
        if let builtIn = builtIn(raw.uppercased()) { return builtIn }
        if let directory = cursorsDirectory, let url = CursorFile.file(named: raw, in: directory),
           let cursor = fileCursor(url) {
            return cursor
        }
        return .pointingHand
    }

    private static func builtIn(_ name: String) -> NSCursor? {
        switch name {
        case "HAND": return .pointingHand
        case "TEXT": return .iBeam
        case "CROSS": return .crosshair
        case "NO": return .operationNotAllowed
        case "SIZE_WE": return .resizeLeftRight
        case "SIZE_NS": return .resizeUpDown
        case "SIZE_NWSE": return diagonal(fromTopLeft: true)
        case "SIZE_NESW": return diagonal(fromTopLeft: false)
        case "SIZE_ALL": return Drawn.sizeAll
        case "HELP": return Drawn.help
        case "BUSY": return Drawn.busy
        case "WAIT": return Drawn.wait
        case "PEN": return Drawn.pen
        case "UPARROW": return Drawn.upArrow
        default: return nil
        }
    }

    private static func diagonal(fromTopLeft: Bool) -> NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: fromTopLeft ? .topLeft : .topRight, directions: .all)
        }
        return fromTopLeft ? Drawn.sizeNWSE : Drawn.sizeNESW
    }

    // MARK: Drawn cursors

    private enum Drawn {
        static let sizeAll = symbol("arrow.up.and.down.and.arrow.left.and.right", hotSpot: .center)
        static let sizeNWSE = symbol("arrow.up.left.and.arrow.down.right", hotSpot: .center)
        static let sizeNESW = symbol("arrow.up.right.and.arrow.down.left", hotSpot: .center)
        static let wait = symbol("hourglass", hotSpot: .center)
        static let pen = symbol("pencil", hotSpot: .bottomLeft)
        static let upArrow = symbol("arrow.up", hotSpot: .top)
        static let help = arrow(badge: "questionmark.circle.fill")
        static let busy = arrow(badge: "hourglass.circle.fill")
    }

    private enum HotSpot { case center, top, bottomLeft }

    private static let canvas = NSSize(width: 24, height: 24)

    /// A cursor that is one SF Symbol, about 16 points tall, on a 24-point canvas.
    private static func symbol(_ name: String, hotSpot: HotSpot) -> NSCursor {
        guard let glyph = glyph(name, pointSize: 15) else { return .arrow }
        let rect = NSRect(x: ((canvas.width - glyph.size.width) / 2).rounded(),
                          y: ((canvas.height - glyph.size.height) / 2).rounded(),
                          width: glyph.size.width, height: glyph.size.height)
        let image = NSImage(size: canvas, flipped: true) { _ in
            drawOutlined(glyph, in: rect, colors: [.black])
            return true
        }
        let point: NSPoint
        switch hotSpot {
        case .center: point = NSPoint(x: canvas.width / 2, y: canvas.height / 2)
        case .top: point = NSPoint(x: canvas.width / 2, y: rect.minY + 1)
        case .bottomLeft: point = NSPoint(x: rect.minX + 1, y: rect.maxY - 1)
        }
        return NSCursor(image: image, hotSpot: point)
    }

    /// The system arrow with a small badge below its tip (Windows' Help and Working in Background cursors).
    private static func arrow(badge name: String) -> NSCursor {
        let arrow = NSCursor.arrow
        guard let badge = glyph(name, pointSize: 10) else { return arrow }
        let arrowSize = arrow.image.size
        let badgeRect = NSRect(x: (arrowSize.width * 0.55).rounded(), y: (arrowSize.height * 0.5).rounded(),
                               width: badge.size.width, height: badge.size.height)
        let size = NSSize(width: max(arrowSize.width, badgeRect.maxX + 2), height: max(arrowSize.height, badgeRect.maxY + 2))
        let image = NSImage(size: size, flipped: true) { _ in
            arrow.image.draw(in: NSRect(origin: .zero, size: arrowSize), from: .zero, operation: .sourceOver,
                             fraction: 1, respectFlipped: true, hints: nil)
            // The badge's symbol in white on a black circle.
            drawOutlined(badge, in: badgeRect, colors: [.white, .black])
            return true
        }
        return NSCursor(image: image, hotSpot: arrow.hotSpot)
    }

    private static func glyph(_ name: String, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
    }

    /// The glyph in `colors` (one per symbol layer) with a white outline, like the system cursors.
    private static func drawOutlined(_ glyph: NSImage, in rect: NSRect, colors: [NSColor]) {
        let outline = glyph.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) ?? glyph
        let fill = glyph.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: colors)) ?? glyph
        for dx in [-1.5, 0, 1.5] {
            for dy in [-1.5, 0, 1.5] where dx != 0 || dy != 0 {
                outline.draw(in: rect.offsetBy(dx: dx, dy: dy), from: .zero, operation: .sourceOver, fraction: 1,
                             respectFlipped: true, hints: nil)
            }
        }
        fill.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Cursor files

    /// Decoded files by path, reloaded when the file's modification date changes; nil caches an unreadable file.
    private static var files: [String: (date: Date?, cursor: NSCursor?)] = [:]
    /// Larger files are not cursors.
    private static let maximumFileSize = 4 << 20

    static func fileCursor(_ url: URL) -> NSCursor? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate
        if let cached = files[url.path], cached.date == date { return cached.cursor }
        var cursor: NSCursor?
        if (values?.fileSize ?? 0) <= maximumFileSize, var data = try? Data(contentsOf: url) {
            if url.pathExtension.lowercased() == "ani" { data = CursorFile.firstAnimatedFrame(in: data) ?? Data() }
            cursor = self.cursor(iconData: data)
        }
        files[url.path] = (date, cursor)
        return cursor
    }

    /// A cursor from `.cur` / `.ico` data: 32 points (or the image's own size when smaller), with a sharper image for
    /// Retina displays when the file has one.
    static func cursor(iconData data: Data) -> NSCursor? {
        let entries = CursorFile.entries(in: data)
        guard let base = CursorFile.bestEntry(entries, scale: 1),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Image indexes follow the directory; a decoder that disagrees gets its first image only.
        let indexed = CGImageSourceGetCount(source) == entries.count
        let width = min(Double(base.width), 32)
        let factor = width / Double(base.width)
        let size = NSSize(width: width, height: (Double(base.height) * factor).rounded())
        let image = NSImage(size: size)
        var chosen = [base]
        if let retina = CursorFile.bestEntry(entries, scale: 2), retina.index != base.index { chosen.append(retina) }
        for entry in chosen where indexed || entry.index == base.index {
            guard let cg = CGImageSourceCreateImageAtIndex(source, indexed ? entry.index : 0, nil) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = size
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        return NSCursor(image: image, hotSpot: NSPoint(x: Double(base.hotSpotX) * factor,
                                                       y: Double(base.hotSpotY) * factor))
    }
}
