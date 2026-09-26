import Foundation

// `MacGlass`: Liquid Glass behind a skin or behind one of its meters. A Deskset extension with no Rainmeter
// counterpart (docs/compat/engine.md, "MacGlass"); every Mac-only option name starts with `Mac`, so a skin that uses
// them still loads unchanged in Rainmeter, which ignores options it does not know.
//
// - `[Rainmeter]`: `MacGlass=None|Regular|Clear` puts glass behind the whole skin (its width × height),
//   `MacGlassCornerRadius=` rounds it (points, default 0), `MacGlassTint=` tints it (a color, optional).
// - Any meter: the same three options put glass behind the meter's frame. A Shape meter whose first shape is a
//   Rectangle that is not rotated, scaled or skewed uses that rectangle and its corner radius instead
//   (`MacGlassCornerRadius` still wins when given).
//
// The engine only works out where the glass goes (`GlassRegion` values, in skin points) after each layout and tells
// the host when the list changed (`SkinHost.skinGlassRegionsChanged`); the host makes the glass. Hidden meters,
// meters of zero size, meters inside a hidden container and meters turned by a TransformationMatrix have none.

/// `MacGlass=Regular` / `Clear`.
public enum GlassStyle: String, Equatable, CaseIterable {
    case regular = "Regular"
    case clear = "Clear"
}

/// The `MacGlass…` options of one section, as read (nil when `MacGlass` is missing, `None` or not a style).
public struct GlassOptions: Equatable {
    public var style: GlassStyle
    /// `MacGlassCornerRadius` (points, not negative); nil when not given.
    public var cornerRadius: Double?
    public var tint: RGBA?

    public init(style: GlassStyle, cornerRadius: Double? = nil, tint: RGBA? = nil) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.tint = tint
    }

    /// The style `MacGlass` names (case-insensitive): nil for `None`, an empty value and anything else (`invalid`
    /// is then true, so the caller can log it).
    public static func style(_ text: String) -> (style: GlassStyle?, invalid: Bool) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.caseInsensitiveCompare("None") == .orderedSame { return (nil, false) }
        if let s = GlassStyle.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame }) {
            return (s, false)
        }
        return (nil, true)
    }

    /// Reads the options through `lookup` (the option's resolved text, nil when missing). `invalid` gets a
    /// `MacGlass` value that is not a style.
    static func read(_ lookup: (String) -> String?, invalid: (String) -> Void) -> GlassOptions? {
        guard let raw = lookup("MacGlass") else { return nil }
        let (style, bad) = GlassOptions.style(raw)
        if bad { invalid(raw.trimmingCharacters(in: .whitespaces)) }
        guard let style else { return nil }
        var options = GlassOptions(style: style)
        if let text = lookup("MacGlassCornerRadius"), !text.trimmingCharacters(in: .whitespaces).isEmpty,
           let r = OptionValue.number(text), r.isFinite {
            options.cornerRadius = r.clamped(0, Meter.maxCoordinate)
        }
        if let text = lookup("MacGlassTint"), !text.trimmingCharacters(in: .whitespaces).isEmpty {
            options.tint = OptionValue.color(text)
        }
        return options
    }
}

/// Where one piece of glass goes: a plain value, so it can travel to the host (and, later, in a skin's snapshot to
/// the main thread; docs/skin-threading.md §5.5).
public struct GlassRegion: Equatable {
    /// `id` of the glass behind the whole skin (`[Rainmeter]`, which is never a meter's name).
    public static let skinID = "Rainmeter"

    /// The meter's name, or `skinID`.
    public var id: String
    /// Skin coordinates (points), not empty.
    public var rect: SkinRect
    /// Points, at most half the shorter side.
    public var cornerRadius: Double
    public var style: GlassStyle
    public var tint: RGBA?
    /// The frame of the meter's container (`Container=`), which cuts off what lies outside it; nil when the glass
    /// lies inside it anyway or the meter is not content of a container.
    public var clip: SkinRect?

    public init(id: String, rect: SkinRect, cornerRadius: Double = 0, style: GlassStyle = .regular, tint: RGBA? = nil,
                clip: SkinRect? = nil) {
        self.id = id
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.style = style
        self.tint = tint
        self.clip = clip
    }

    /// The most regions one skin gets (judgment: every piece of glass is a view the window server renders on every
    /// frame; a skin with thousands of glass meters must not bring the Mac to a crawl). Later meters get none.
    public static let maxRegions = 64
}

extension Meter {
    /// The glass behind this meter as it is laid out now (see the notes at the top of Glass.swift), or nil.
    public var glassRegion: GlassRegion? {
        guard let glass, !hidden else { return nil }
        var rect = frame
        var radius = glass.cornerRadius
        if let shape = self as? ShapeMeter, let first = shape.shapes.first, let r = first.rectangle {
            let origin = contentFrame
            rect = SkinRect(x: origin.x + r.x, y: origin.y + r.y, width: r.width, height: r.height)
            if radius == nil { radius = r.cornerRadius }
        }
        if let m = transformationMatrix {
            // Moved only: the glass moves with it. Turned, scaled or skewed: the glass could not follow.
            guard m[0] == 1, m[1] == 0, m[2] == 0, m[3] == 1 else { return nil }
            rect.x += m[4]
            rect.y += m[5]
        }
        guard rect.width > 0, rect.height > 0, rect.x.isFinite, rect.y.isFinite, rect.maxX.isFinite,
              rect.maxY.isFinite else { return nil }
        var clip: SkinRect?
        if let container {
            guard !container.hidden else { return nil }
            let c = container.frame
            let left = max(rect.x, c.x), top = max(rect.y, c.y)
            let right = min(rect.maxX, c.maxX), bottom = min(rect.maxY, c.maxY)
            guard right > left, bottom > top else { return nil }
            if rect.x < c.x || rect.y < c.y || rect.maxX > c.maxX || rect.maxY > c.maxY { clip = c }
        }
        let limit = min(rect.width, rect.height) / 2
        return GlassRegion(id: name, rect: rect, cornerRadius: min(max(radius ?? 0, 0), limit), style: glass.style,
                           tint: glass.tint, clip: clip)
    }

    /// Reads the meter's `MacGlass…` options (see `Meter.readOptions`).
    func readGlassOptions() -> GlassOptions? {
        GlassOptions.read({ option($0) }) { value in
            guard !awaitsSectionVariables("MacGlass") else { return }
            skin.logOnce("MacGlass=\(value) on [\(name)] is not None, Regular or Clear", level: .warning)
        }
    }
}

extension Skin {
    /// The `[Rainmeter]` section's `MacGlass…` options, read now. Unlike the other `[Rainmeter]` options they are
    /// read again at every redraw, with variables and section variables resolved, like `ContextTitle` (so
    /// `!SetVariable` and `!SetOption Rainmeter MacGlass …` apply without a refresh).
    func skinGlassOptions() -> GlassOptions? {
        guard let root = rainmeterSection else { return nil }
        return GlassOptions.read({ key in
            root.rawOption(key).map { resolve($0, in: root, sectionVariables: true) }
        }) { value in
            logOnce("MacGlass=\(value) in [Rainmeter] is not None, Regular or Clear", level: .warning)
        }
    }

    /// Where the skin's glass goes as it is laid out now: the skin's own first (behind everything), then the meters'
    /// in file order (later ones in front), at most `GlassRegion.maxRegions`. Nothing before the first update has
    /// sized the skin.
    public func currentGlassRegions() -> [GlassRegion] {
        var regions: [GlassRegion] = []
        guard updateCount > 0 else { return regions }
        if let g = skinGlassOptions() {
            let limit = min(width, height) / 2
            regions.append(GlassRegion(id: GlassRegion.skinID, rect: SkinRect(x: 0, y: 0, width: width, height: height),
                                       cornerRadius: min(max(g.cornerRadius ?? 0, 0), limit), style: g.style,
                                       tint: g.tint))
        }
        for meter in meters where meter.glass != nil {
            guard let region = meter.glassRegion else { continue }
            guard regions.count < GlassRegion.maxRegions else {
                logOnce("More than \(GlassRegion.maxRegions) meters with MacGlass: the others get none", level: .warning)
                break
            }
            regions.append(region)
        }
        return regions
    }
}
