import AppKit
import DesksetCore

/// The inspector's type and color: four levels of type (a serif title of 21 pt, section headings of 13 pt semibold,
/// rows of 12–12.5 pt, notes of 11–11.5 pt), quiet ink for labels and notes (black 58 % in light, white 62 % in dark:
/// about 5.3 : 1 and 6.6 : 1, where `secondaryLabelColor` is 3.95 : 1 in light), hairlines between sections, 16 pt
/// side margins. The serif is the signature, and only titles use it: New York, or Songti SC in Chinese.
enum StudioPageStyle {
    static let margin: CGFloat = 16
    static let labelWidth: CGFloat = 76

    // MARK: Type

    /// The title of a page or a popover: New York semibold, Songti SC bold in Chinese.
    static func titleFont(_ size: CGFloat = 21) -> NSFont {
        if StudioText.language == .chinese {
            return NSFont(name: "STSongti-SC-Bold", size: size - 1) ?? .systemFont(ofSize: size - 1, weight: .semibold)
        }
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    static let headingFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let labelFont = NSFont.systemFont(ofSize: 12)
    static let valueFont = NSFont.systemFont(ofSize: 12.5)
    static let noteFont = NSFont.systemFont(ofSize: 11.5)
    static let smallFont = NSFont.systemFont(ofSize: 11)

    static func monospaced(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: Color

    /// Labels and notes.
    static let quietInk = NSColor(name: "StudioQuietInk") { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.62) : NSColor(white: 0, alpha: 0.58)
    }

    /// Placeholders and chevrons only.
    static let faintInk = NSColor(name: "StudioFaintInk") { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.40) : NSColor(white: 0, alpha: 0.36)
    }

    /// The fill of fields, capsules and tracks.
    static let fieldFill = NSColor(name: "StudioFieldFill") { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.05)
    }

    static let hairline = NSColor.separatorColor
    static let okGreen = NSColor(srgbRed: 0.20, green: 0.66, blue: 0.33, alpha: 1)
    static let attention = NSColor(srgbRed: 0.93, green: 0.58, blue: 0.10, alpha: 1)
    static let attentionText = NSColor(name: "StudioAttentionText") { appearance in
        isDark(appearance) ? NSColor(srgbRed: 1, green: 0.72, blue: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.62, green: 0.34, blue: 0, alpha: 1)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func color(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: c.a / 255)
    }

    // MARK: Pieces

    /// A label in quiet ink.
    static func label(_ text: String, font: NSFont = labelFont, color: NSColor = quietInk) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// A label that wraps over several lines.
    static func wrapping(_ text: String, font: NSFont = noteFont, color: NSColor = quietInk) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        return field
    }

    /// An SF Symbol at a point size, in a color.
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// The height a wrapping label needs for `text` in `font` at `width` (measured by a label's own cell: a label
    /// draws a line taller than the font's leading says, so a height worked out from the text alone cuts the last
    /// line).
    static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        measuring.font = font
        measuring.stringValue = text
        let size = measuring.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(width, 1), height: 10_000))
        return ceil(size?.height ?? 0)
    }

    private static let measuring = NSTextField(wrappingLabelWithString: "")
}
