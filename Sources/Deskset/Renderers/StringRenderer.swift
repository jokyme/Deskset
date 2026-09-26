import AppKit
import CoreText
import DesksetCore

// String meter measuring and drawing with CoreText. `textSize` (the host's SkinHost.textSize) and `drawString`
// both go through `TextLayout.make`, so the measured size is exactly what gets drawn.
//
// Rules (manual: String meter, Inline Options, [Rainmeter] AccurateText; judgment calls marked):
// - Sizes: FontSize is in points at 96 DPI → pixels = points × 96/72 (1 skin pixel = 1 macOS point).
// - Line height = ascent + descent + line gap of the tallest run on the line (DirectWrite-style metrics).
// - Width = widest line; trailing whitespace is not counted, except at the end of a paragraph with
//   TrailingSpaces=1 (Judgment: DirectWrite reports widths without trailing whitespace).
// - AccurateText=0 adds 1/6 em of horizontal padding on each side (GDI+-like), text is inset by it.
// - StringAlign aligns every line inside the meter's content box; vertical alignment moves the block of lines.
// - ClipString: 1 → lines wider than the box end in "…"; with wrapping (W and H given) lines that do not fit in H
//   are dropped and the last visible line ends in "…". 2 → wraps on word boundaries only (spaces / tabs, and
//   between characters of scripts written without spaces: see `TextWrapRules`), a word wider than the box is
//   clipped (no ellipsis); lines beyond the height are dropped with "…" on the last one (Judgment). Clipping uses
//   the meter's content box (inside Padding).
// - Tabs: stops every 4 × the font size (`TextStyle.tabInterval`, DirectWrite's default).
// - StringEffect Shadow: copy offset 1px right/down; Border: 1px outline (a 2px stroke behind the text); both in
//   FontEffectColor and unaffected by inline colors.
// - Angle rotates around the StringAlign anchor (the meter's X/Y); positive = clockwise. (Judgment: the manual
//   only says size and position are computed as if the text were horizontal.)
// - AntiAlias=0 draws aliased text (manual: "If set to 1, antialiasing (edge smoothing) is used").
// - Inline: Face/Size/Weight/Italic/Oblique/Stretch/Typography change the run's font; Color the fill;
//   CharacterSpacing adds DIP before/after every character (the first character of a line is indented by its
//   leading space); Underline/Strikethrough draw lines in the run color; Shadow draws a blurred drop shadow
//   clipped to the meter ("the shadow drawing surface [is] the size of the meter itself"); GradientColor fills the
//   selected glyphs of each line with a gradient across the selection's box (per line, "Gradients will not wrap").

extension SkinRenderer {
    // MARK: String

    /// AppKit attributes approximating `style` (compatibility helper; the String meter itself uses `TextLayout`).
    static func attributes(for style: TextStyle, color: RGBA? = nil) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        switch style.horizontalAlign {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        switch style.clip {
        case 1: paragraph.lineBreakMode = .byTruncatingTail
        case 2: paragraph.lineBreakMode = .byWordWrapping
        default: paragraph.lineBreakMode = .byClipping
        }
        return [.font: Fonts.font(for: style), .foregroundColor: (color ?? style.color).nsColor,
                .paragraphStyle: paragraph]
    }

    static func textSize(_ text: String, style: TextStyle, wrapWidth: Double?) -> (width: Double, height: Double) {
        guard !text.isEmpty, style.fontSize > 0 else { return (0, 0) }
        return TextLayout.make(text, style: style, wrapWidth: wrapWidth.map { CGFloat($0) }).size
    }

    static func drawString(_ meter: StringMeter, _ ctx: CGContext) {
        let text = meter.text
        let style = meter.style
        guard !text.isEmpty, style.fontSize > 0 else { return }
        let box = meter.contentFrame.cgRect
        // Clipped text in an empty box shows nothing (and must not be wrapped one character per line).
        if style.clip != 0, box.width <= 0 || box.height <= 0 { return }
        let layout = TextLayout.make(text, style: style, wrapWidth: style.wrap ? box.width : nil)
        guard !layout.lines.isEmpty else { return }

        // The text matrix is not part of the graphics state: restore it for whoever draws next.
        let savedTextMatrix = ctx.textMatrix
        ctx.saveGState()
        defer {
            ctx.restoreGState()
            ctx.textMatrix = savedTextMatrix
        }
        if style.angle != 0 {
            let anchor = meter.anchorPoint
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: style.angle)
            ctx.translateBy(x: -anchor.x, y: -anchor.y)
        }
        ctx.setShouldAntialias(style.antiAlias)
        if style.clip != 0 { ctx.clip(to: box) }

        let innerX = box.minX + layout.pad
        let innerWidth = box.width - 2 * layout.pad
        let placed = layout.visibleLines(clip: style.clip, boxHeight: box.height, innerWidth: innerWidth)
        let blockHeight = placed.reduce(0) { $0 + $1.height }
        var y = box.minY
        switch style.verticalAlign {
        case .top: break
        case .center: y += (box.height - blockHeight) / 2
        case .bottom: y += box.height - blockHeight
        }
        var positioned: [(line: TextLayout.Placed, origin: CGPoint)] = []
        positioned.reserveCapacity(placed.count)
        for line in placed {
            let x: CGFloat
            switch style.horizontalAlign {
            case .left: x = innerX
            case .center: x = innerX + (innerWidth - line.width) / 2
            case .right: x = innerX + innerWidth - line.width
            }
            positioned.append((line, CGPoint(x: x + line.indent, y: y + line.ascent)))
            y += line.height
        }
        layout.draw(positioned, in: ctx, style: style, shadowClip: meter.frame.cgRect)
    }
}

/// Custom attributes carried through CoreText runs (the colors are applied by `TextLayout.draw`).
private enum RunKey {
    static let color = "deskset.color" as CFString
    static let underline = "deskset.underline" as CFString
    static let strikethrough = "deskset.strikethrough" as CFString
    static let shadow = "deskset.shadow" as CFString
    static let gradient = "deskset.gradient" as CFString
    static let bold = "deskset.bold" as CFString
    static let slant = "deskset.slant" as CFString
    /// [ascent, descent, leading] replacing the run font's metrics (substituted Windows fonts).
    static let metrics = "deskset.metrics" as CFString
    /// PostScript name of the font the metrics belong to (runs in fallback fonts keep their own metrics).
    static let metricsFont = "deskset.metricsFont" as CFString
}

/// A String meter text laid out into lines (immutable; cached by text, style and wrap width).
final class TextLayout {
    struct Line {
        var line: CTLine
        /// UTF-16 range in the text.
        var range: CFRange
        /// Width used for alignment and measuring.
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var leading: CGFloat
        /// Inline CharacterSpacing leading space before the line's first character (included in `width`).
        var indent: CGFloat = 0
        var height: CGFloat { ascent + descent + leading }
    }

    struct Shadow: Hashable {
        var dx: Double
        var dy: Double
        var blur: Double
        var color: RGBA
    }

    let attributed: NSAttributedString
    let lines: [Line]
    /// Horizontal padding on each side (AccurateText=0).
    let pad: CGFloat
    let textWidth: CGFloat
    let textHeight: CGFloat
    let shadows: [Shadow]
    let gradients: [InlineGradient]
    private let units: [UInt16]
    private var gradientCache: [Int: CGGradient] = [:]
    /// The last `visibleLines` result (clipped meters would otherwise re-truncate their lines on every redraw).
    private var visibleCache: (clip: Int, boxHeight: CGFloat, innerWidth: CGFloat, lines: [Placed])?

    private init(attributed: NSAttributedString, units: [UInt16], lines: [Line], pad: CGFloat, shadows: [Shadow],
                 gradients: [InlineGradient]) {
        self.attributed = attributed
        self.units = units
        self.lines = lines
        self.pad = pad
        self.shadows = shadows
        self.gradients = gradients
        textWidth = lines.map(\.width).max() ?? 0
        textHeight = lines.reduce(0) { $0 + $1.height }
    }

    /// Measured size in skin points (rounded up to whole pixels; an empty text is 0×0).
    var size: (width: Double, height: Double) {
        guard !lines.isEmpty else { return (0, 0) }
        return (Double(ceil(max(textWidth + 2 * pad, 0) - 0.001)), Double(ceil(textHeight - 0.001)))
    }

    // MARK: Cache

    private struct Key: Hashable {
        var text: String
        var style: TextStyle
        var wrapWidth: CGFloat?
        var generation: Int
    }
    /// Two-generation cache: layouts used since the last rotation live in `cache`, the ones before in `previous`.
    /// Every layout a redraw needs survives a rotation as long as one redraw uses fewer than `cacheLimit` of them
    /// (a plain "clear when full" cache would rebuild every layout on every redraw once all the loaded skins
    /// together show more strings than the limit).
    private static var cache: [Key: TextLayout] = [:]
    private static var previous: [Key: TextLayout] = [:]
    static let cacheLimit = 1024
    /// Judgment: lines beyond this are dropped (bounds the work for runaway texts).
    static let maximumLines = 5_000

    static func make(_ text: String, style: TextStyle, wrapWidth: CGFloat?) -> TextLayout {
        // The skin's @Resources/Fonts must be loaded before FontFace is resolved (a no-op after the first time).
        if let folder = style.fontFolder { Fonts.registerFolder(folder) }
        let key = Key(text: text, style: style, wrapWidth: wrapWidth, generation: Fonts.generation)
        if let hit = cache[key] { return hit }
        let layout = previous[key] ?? build(text, style: style, wrapWidth: wrapWidth)
        if cache.count >= cacheLimit {
            previous = cache
            cache = [:]
            cache.reserveCapacity(cacheLimit)
        }
        cache[key] = layout
        return layout
    }

    // MARK: Building

    private static func build(_ text: String, style: TextStyle, wrapWidth: CGFloat?) -> TextLayout {
        let built = attributedString(text, style: style)
        let attributed = built.string
        let units = built.units
        let n = units.count
        let pixelSize = CGFloat(TextStyle.pixelSize(points: style.fontSize))
        let pad = style.accurateText ? 0 : pixelSize * CGFloat(TextStyle.gdiPaddingFactor)
        guard n > 0 else {
            return TextLayout(attributed: attributed, units: units, lines: [], pad: pad, shadows: [], gradients: [])
        }
        let base = Fonts.resolve(Fonts.request(for: style))
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let available = wrapWidth.map { max($0 - 2 * pad, 1) }
        var lines: [Line] = []
        var start = 0
        while start < n, lines.count < maximumLines {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(available ?? 1e7))
            if count <= 0 { count = max(CTTypesetterSuggestClusterBreak(typesetter, start, 1e7), 1) }
            count = min(count, n - start)
            if available != nil, !style.breakLongWords {
                count = TextWrapRules.wordBoundaryBreak(units, start: start, count: count)
            }
            let range = CFRange(location: start, length: count)
            let ctLine = CTTypesetterCreateLine(typesetter, range)
            let last = units[start + count - 1]
            let paragraphEnd = start + count == n || isNewline(last)
            var line = makeLine(ctLine, range: range, keepTrailing: style.trailingSpaces && paragraphEnd, base: base)
            // The leading space of the line's first character: inside a line it is the previous character's kern,
            // at the start of a line there is no previous character to carry it.
            if !built.leads.isEmpty, built.leads[start] != 0 {
                line.indent = built.leads[start]
                line.width = max(line.width + line.indent, 0)
            }
            lines.append(line)
            start += count
        }
        return TextLayout(attributed: attributed, units: units, lines: lines, pad: pad, shadows: built.shadows,
                          gradients: built.gradients)
    }

    private static func makeLine(_ ctLine: CTLine, range: CFRange, keepTrailing: Bool, base: Fonts.Resolved) -> Line {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        // Line metrics = the largest of its runs' metrics, using the stand-in metrics where a run carries them.
        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            _ = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &a, &d, &l)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            if let m = attributes[RunKey.metrics] as? [CGFloat], m.count == 3,
               let owner = attributes[RunKey.metricsFont] as? String,
               let font = attributes[kCTFontAttributeName], CFGetTypeID(font as CFTypeRef) == CTFontGetTypeID(),
               CTFontCopyPostScriptName(font as! CTFont) as String == owner {
                (a, d, l) = (m[0], m[1], m[2])
            }
            ascent = max(ascent, a)
            descent = max(descent, d)
            leading = max(leading, l)
        }
        if ascent + descent <= 0 {
            if let m = base.lineMetrics {
                (ascent, descent, leading) = (m.ascent, m.descent, m.leading)
            } else {
                ascent = CTFontGetAscent(base.font)
                descent = CTFontGetDescent(base.font)
                leading = CTFontGetLeading(base.font)
            }
        }
        let visible = keepTrailing ? width : width - CGFloat(CTLineGetTrailingWhitespaceWidth(ctLine))
        return Line(line: ctLine, range: range, width: max(visible, 0), ascent: ascent, descent: max(descent, 0),
                    leading: max(leading, 0))
    }

    private static func isNewline(_ u: UInt16) -> Bool { TextWrapRules.isNewline(u) }

    private static func isSpace(_ u: UInt16) -> Bool { TextWrapRules.isSpace(u) }

    private struct Built {
        var string: NSAttributedString
        var units: [UInt16]
        var shadows: [Shadow]
        var gradients: [InlineGradient]
        /// CharacterSpacing leading space before each unit (empty when no span sets spacing).
        var leads: [CGFloat]
    }

    /// Applies the base style and the inline spans. Spans are applied in order, so a later span of the same kind
    /// wins where two overlap.
    private static func attributedString(_ text: String, style: TextStyle) -> Built {
        var units = Array(text.utf16)
        let n = units.count
        let spans = style.inlineSpans.filter { $0.length > 0 && $0.location >= 0 && $0.location < n }
        var cuts = Set<Int>([0, n])
        for s in spans {
            cuts.insert(s.location)
            cuts.insert(min(s.end, n))
        }
        let bounds = cuts.sorted()
        let starts = spans.indices.sorted { spans[$0].location < spans[$1].location }
        var nextStart = 0
        var active: [Int] = []

        struct Segment {
            var range: CFRange
            var resolved: Fonts.Resolved
            var color: RGBA
            var underline = false
            var strikethrough = false
            var spacing: (leading: Double, trailing: Double, minimum: Double)?
            var shadow: Int?
            var gradient: Int?
        }
        var segments: [Segment] = []
        var shadows: [Shadow] = []
        var shadowIndex: [Shadow: Int] = [:]
        var gradients: [InlineGradient] = []
        /// Span index → gradient slot: every selected range gets its own gradient box (Judgment: "a color gradient
        /// ... to be used on the selected text"; two matches of one pattern are two selections).
        var gradientIndex: [Int: Int] = [:]
        let baseRequest = Fonts.request(for: style)

        for (a, b) in zip(bounds, bounds.dropFirst()) where b > a {
            active.removeAll { spans[$0].end <= a }
            while nextStart < starts.count, spans[starts[nextStart]].location <= a {
                if spans[starts[nextStart]].end > a { active.append(starts[nextStart]) }
                nextStart += 1
            }
            active.sort()
            var request = baseRequest
            var segment = Segment(range: CFRange(location: a, length: b - a), resolved: Fonts.resolve(baseRequest),
                                  color: style.color)
            for index in active {
                switch spans[index].setting {
                case .face(let face): request.face = face
                case .size(let size): request.size = CGFloat(TextStyle.pixelSize(points: size))
                case .color(let color): segment.color = color
                case .weight(let weight): request.weight = weight
                case .italic: request.italic = true
                case .oblique: request.oblique = true
                case .underline: segment.underline = true
                case .strikethrough: segment.strikethrough = true
                case .stretch(let stretch): request.stretch = stretch
                case .typography(let feature, let value):
                    request.features.removeAll { $0.tag == feature }
                    request.features.append(Fonts.Feature(tag: feature, value: value))
                case .characterSpacing(let leading, let trailing, let minimum):
                    segment.spacing = (leading, trailing, minimum)
                case .shadow(let dx, let dy, let blur, let color):
                    let shadow = Shadow(dx: dx, dy: dy, blur: blur, color: color)
                    if let i = shadowIndex[shadow] {
                        segment.shadow = i
                    } else {
                        shadowIndex[shadow] = shadows.count
                        segment.shadow = shadows.count
                        shadows.append(shadow)
                    }
                case .gradient(let gradient):
                    if let i = gradientIndex[index] {
                        segment.gradient = i
                    } else {
                        gradientIndex[index] = gradients.count
                        segment.gradient = gradients.count
                        gradients.append(gradient)
                    }
                case .textCase, .none:
                    break
                }
            }
            if request != baseRequest { segment.resolved = Fonts.resolve(request) }
            if let map = segment.resolved.characterMap {
                for i in a..<b { if let m = map[units[i]] { units[i] = m } }
            }
            segments.append(segment)
        }

        let string = NSString(characters: units, length: n) as String
        let attributed = NSMutableAttributedString(string: string)
        let paragraph = paragraphStyle(tabInterval: CGFloat(style.tabInterval))
        var kerns = [CGFloat](repeating: 0, count: segments.contains { $0.spacing != nil } ? n : 0)
        var leads = kerns
        for segment in segments {
            var attributes: [CFString: Any] = [
                kCTFontAttributeName: segment.resolved.font,
                kCTForegroundColorFromContextAttributeName: true,
                kCTParagraphStyleAttributeName: paragraph,
                RunKey.color: segment.color.cgColor,
            ]
            if segment.resolved.syntheticBold { attributes[RunKey.bold] = true }
            if segment.resolved.slant != 0 { attributes[RunKey.slant] = segment.resolved.slant }
            if let m = segment.resolved.lineMetrics {
                attributes[RunKey.metrics] = [m.ascent, m.descent, m.leading]
                attributes[RunKey.metricsFont] = CTFontCopyPostScriptName(segment.resolved.font)
            }
            if segment.underline { attributes[RunKey.underline] = true }
            if segment.strikethrough { attributes[RunKey.strikethrough] = true }
            if let s = segment.shadow { attributes[RunKey.shadow] = s }
            if let g = segment.gradient { attributes[RunKey.gradient] = g }
            attributed.setAttributes(attributes as [NSAttributedString.Key: Any],
                                     range: NSRange(location: segment.range.location, length: segment.range.length))
            if let spacing = segment.spacing {
                let a = segment.range.location, b = a + segment.range.length
                for i in a..<b {
                    kerns[i] += CGFloat(spacing.trailing)
                    leads[i] += CGFloat(spacing.leading)
                    if i > 0 { kerns[i - 1] += CGFloat(spacing.leading) }
                    if spacing.minimum > 0 {
                        var glyph: CGGlyph = 0
                        var unit = units[i]
                        if CTFontGetGlyphsForCharacters(segment.resolved.font, &unit, &glyph, 1) {
                            var advance = CGSize.zero
                            CTFontGetAdvancesForGlyphs(segment.resolved.font, .horizontal, &glyph, &advance, 1)
                            if advance.width < CGFloat(spacing.minimum) { kerns[i] += CGFloat(spacing.minimum) - advance.width }
                        }
                    }
                }
            }
        }
        if !kerns.isEmpty {
            var i = 0
            while i < n {
                var j = i + 1
                while j < n, kerns[j] == kerns[i] { j += 1 }
                if kerns[i] != 0 {
                    attributed.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: kerns[i],
                                            range: NSRange(location: i, length: j - i))
                }
                i = j
            }
        }
        return Built(string: attributed, units: units, shadows: shadows, gradients: gradients, leads: leads)
    }

    /// Tab stops every `tabInterval` pixels from the start of the line (no explicit stops), like DirectWrite's
    /// default incremental tab stop (see `TextStyle.tabInterval`).
    private static func paragraphStyle(tabInterval: CGFloat) -> CTParagraphStyle {
        var interval = tabInterval.isFinite ? max(tabInterval, 1) : 1
        var stops = [] as CFArray
        return withUnsafeBytes(of: &interval) { intervalBytes in
            withUnsafeBytes(of: &stops) { stopBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size,
                                            value: intervalBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size,
                                            value: stopBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    // MARK: Visible lines (clipping)

    struct Placed {
        var line: CTLine
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var leading: CGFloat
        var indent: CGFloat = 0
        var height: CGFloat { ascent + descent + leading }
    }

    /// The lines to draw: all of them without clipping; otherwise those that fit in the box height (at least one),
    /// with ellipses where ClipString asks for them.
    func visibleLines(clip: Int, boxHeight: CGFloat, innerWidth: CGFloat) -> [Placed] {
        func placed(_ l: Line) -> Placed {
            Placed(line: l.line, width: l.width, ascent: l.ascent, descent: l.descent, leading: l.leading,
                   indent: l.indent)
        }
        guard clip != 0 else { return lines.map(placed) }
        if let c = visibleCache, c.clip == clip, c.boxHeight == boxHeight, c.innerWidth == innerWidth { return c.lines }
        var count = 0
        var used: CGFloat = 0
        for l in lines {
            if count > 0, used + l.height > boxHeight + 0.5 { break }
            used += l.height
            count += 1
        }
        var result = lines.prefix(count).map(placed)
        let available = max(innerWidth, 0)
        if clip == 1 {
            for i in result.indices where result[i].width > available + 0.5 {
                let indent = result[i].indent
                if let truncated = truncate(result[i].line, to: max(available - indent, 0)) {
                    result[i].line = truncated
                    result[i].width = max(visibleWidth(truncated) + indent, 0)
                }
            }
        }
        if count < lines.count, let lastIndex = result.indices.last {
            let indent = result[lastIndex].indent
            let replacement = ellipsisLine(lines[lastIndex], available: max(available - indent, 0))
            result[lastIndex].line = replacement
            result[lastIndex].width = max(visibleWidth(replacement) + indent, 0)
        }
        visibleCache = (clip, boxHeight, innerWidth, result)
        return result
    }

    private func visibleWidth(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
    }

    private func ellipsisToken(at index: Int) -> CTLine {
        let i = min(max(index, 0), max(attributed.length - 1, 0))
        let attributes = attributed.length > 0 ? attributed.attributes(at: i, effectiveRange: nil) : [:]
        return CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
    }

    private func truncate(_ line: CTLine, to width: CGFloat) -> CTLine? {
        let range = CTLineGetStringRange(line)
        return CTLineCreateTruncatedLine(line, Double(width), .end, ellipsisToken(at: range.location + range.length - 1))
    }

    /// Last visible line when more lines were cut: its own text + "…" when that fits, else the rest of the
    /// paragraph truncated with "…".
    private func ellipsisLine(_ line: Line, available: CGFloat) -> CTLine {
        let start = line.range.location
        var end = start + line.range.length
        while end > start, TextLayout.isNewline(units[end - 1]) || TextLayout.isSpace(units[end - 1]) { end -= 1 }
        let own = NSMutableAttributedString(attributedString: attributed.attributedSubstring(
            from: NSRange(location: start, length: end - start)))
        let tokenAttributes = attributed.attributes(at: max(end - 1, start), effectiveRange: nil)
        own.append(NSAttributedString(string: "\u{2026}", attributes: tokenAttributes))
        let candidate = CTLineCreateWithAttributedString(own)
        if visibleWidth(candidate) <= available + 0.5 { return candidate }
        var paragraphEnd = start
        while paragraphEnd < units.count, !TextLayout.isNewline(units[paragraphEnd]) { paragraphEnd += 1 }
        let rest = CTLineCreateWithAttributedString(attributed.attributedSubstring(
            from: NSRange(location: start, length: paragraphEnd - start)))
        return CTLineCreateTruncatedLine(rest, Double(available), .end, ellipsisToken(at: max(end - 1, start)))
            ?? candidate
    }
}

// MARK: - Drawing

extension TextLayout {
    /// Draws the lines, each with its baseline starting at its origin (flipped context): the StringEffect copies
    /// behind everything, then the inline-shadowed runs, then the rest.
    ///
    /// Each inline Shadow is one transparency layer for the whole meter (not one per line), clipped to the meter
    /// ("the shadow drawing surface [is] the size of the meter itself") and to the area the shadowed text, its
    /// offset copy and the blur can reach — blurring a meter-sized layer per line made shadowed text the most
    /// expensive thing to redraw.
    func draw(_ lines: [(line: Placed, origin: CGPoint)], in ctx: CGContext, style: TextStyle, shadowClip: CGRect) {
        struct Prepared {
            var origin: CGPoint
            var runs: [(run: CTRun, attributes: RunAttributes)]
            var gradientBoxes: [Int: CGRect]
        }
        var prepared: [Prepared] = []
        prepared.reserveCapacity(lines.count)
        var shadowIndices = Set<Int>()
        for (line, origin) in lines {
            guard let runs = CTLineGetGlyphRuns(line.line) as? [CTRun], !runs.isEmpty else { continue }
            let described = runs.map { (run: $0, attributes: RunAttributes($0)) }
            var boxes: [Int: CGRect] = [:]
            for (run, a) in described {
                if let g = a.gradient {
                    let rect = runRect(run, at: origin)
                    boxes[g] = boxes[g].map { $0.union(rect) } ?? rect
                }
                if let s = a.shadow, s < shadows.count { shadowIndices.insert(s) }
            }
            prepared.append(Prepared(origin: origin, runs: described, gradientBoxes: boxes))
        }

        for p in prepared { drawEffect(p.runs, at: p.origin, style: style, in: ctx) }

        for index in shadowIndices.sorted() {
            let spec = shadows[index]
            var area = CGRect.null
            for p in prepared {
                for (run, a) in p.runs where a.shadow == index { area = area.union(runRect(run, at: p.origin)) }
            }
            guard !area.isNull else { continue }
            // Glyphs can overhang their boxes (italics, simulated slant / bold, accents): half a line of margin.
            let margin = CGFloat(spec.blur) * 2 + area.height * 0.5 + 2
            let reach = area.union(area.offsetBy(dx: CGFloat(spec.dx), dy: CGFloat(spec.dy)))
                .insetBy(dx: -margin, dy: -margin)
                .intersection(shadowClip)
            guard !reach.isNull, !reach.isEmpty else { continue }
            ctx.saveGState()
            ctx.clip(to: reach)
            // CGContext shadows are specified in device space: map the offset and blur through the CTM.
            let m = ctx.ctm
            let offset = CGSize(width: spec.dx, height: spec.dy)
                .applying(CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0))
            let scale = sqrt(abs(m.a * m.d - m.b * m.c))
            ctx.setShadow(offset: offset, blur: CGFloat(spec.blur) * scale, color: spec.color.cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for p in prepared {
                for (run, a) in p.runs where a.shadow == index {
                    drawStyled(run, a, at: p.origin, gradientBoxes: p.gradientBoxes, in: ctx)
                }
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        for p in prepared {
            for (run, a) in p.runs where !(a.shadow.map { $0 < shadows.count } ?? false) {
                drawStyled(run, a, at: p.origin, gradientBoxes: p.gradientBoxes, in: ctx)
            }
        }
    }

    /// StringEffect: Shadow = a copy 1px right and down; Border = a 1px outline (a 2px stroke behind the text;
    /// around simulated bold glyphs the outline is their stroked shape, so the stroke is widened by the bold stroke).
    private func drawEffect(_ runs: [(run: CTRun, attributes: RunAttributes)], at origin: CGPoint, style: TextStyle,
                            in ctx: CGContext) {
        switch style.effect {
        case .shadow:
            let shifted = CGPoint(x: origin.x + 1, y: origin.y + 1)
            let color = style.effectColor.cgColor
            for (run, a) in runs {
                drawGlyphs(run, a, at: shifted, color: color, in: ctx)
                drawDecorations(run, a, at: shifted, color: color, in: ctx)
            }
        case .border:
            ctx.saveGState()
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(style.effectColor.cgColor)
            for (run, a) in runs {
                let path = CGMutablePath()
                addGlyphs(run, a, at: origin, to: path)
                guard !path.isEmpty else { continue }
                ctx.addPath(path)
                ctx.setLineWidth(2 + (a.syntheticBold ? a.font.map(TextLayout.syntheticBoldWidth) ?? 0 : 0))
                ctx.strokePath()
            }
            ctx.restoreGState()
        case .none:
            break
        }
    }

    private func drawStyled(_ run: CTRun, _ a: RunAttributes, at origin: CGPoint, gradientBoxes: [Int: CGRect],
                            in ctx: CGContext) {
        let color = a.color ?? CGColor(gray: 0, alpha: 1)
        if let g = a.gradient, let box = gradientBoxes[g], let gradient = cgGradient(g) {
            let path = CGMutablePath()
            addGlyphs(run, a, at: origin, to: path)
            if !path.isEmpty {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                let spec = gradients[g]
                let radians = spec.angle * .pi / 180
                let v = CGPoint(x: cos(radians), y: sin(radians))
                let r = (abs(v.x) * box.width + abs(v.y) * box.height) / 2
                let start = CGPoint(x: box.midX + v.x * r, y: box.midY + v.y * r)
                let end = CGPoint(x: box.midX - v.x * r, y: box.midY - v.y * r)
                ctx.drawLinearGradient(gradient, start: start, end: end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                ctx.restoreGState()
            }
        } else {
            drawGlyphs(run, a, at: origin, color: color, in: ctx)
        }
        drawDecorations(run, a, at: origin, color: color, in: ctx)
    }

    /// Stroke width that simulates bold for `font`.
    static func syntheticBoldWidth(_ font: CTFont) -> CGFloat { max(CTFontGetSize(font) * 0.045, 0.3) }

    private func drawGlyphs(_ run: CTRun, _ a: RunAttributes, at origin: CGPoint, color: CGColor, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(color)
        if a.syntheticBold, let font = a.font {
            // Simulated bold: fill + stroke in the text color.
            ctx.setTextDrawingMode(.fillStroke)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(TextLayout.syntheticBoldWidth(font))
        } else {
            ctx.setTextDrawingMode(.fill)
        }
        // The context is y-down, glyphs are y-up; simulated italic shears x by y (the text matrix is not part of
        // the graphics state, so it is set for every run).
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: a.slant, d: -1, tx: 0, ty: 0)
        ctx.textPosition = origin
        CTRunDraw(run, ctx, CFRange(location: 0, length: 0))
        ctx.restoreGState()
    }

    private func drawDecorations(_ run: CTRun, _ a: RunAttributes, at origin: CGPoint, color: CGColor,
                                 in ctx: CGContext) {
        guard a.underline || a.strikethrough, let font = a.font else { return }
        let rect = runRect(run, at: origin)
        guard rect.width > 0 else { return }
        let thickness = max(CTFontGetUnderlineThickness(font), 0.5)
        ctx.saveGState()
        ctx.setFillColor(color)
        if a.underline {
            let y = origin.y - CTFontGetUnderlinePosition(font)
            ctx.fill(CGRect(x: rect.minX, y: y - thickness / 2, width: rect.width, height: thickness))
        }
        if a.strikethrough {
            let xHeight = CTFontGetXHeight(font)
            let y = origin.y - (xHeight > 0 ? xHeight / 2 : CTFontGetAscent(font) * 0.3)
            ctx.fill(CGRect(x: rect.minX, y: y - thickness / 2, width: rect.width, height: thickness))
        }
        ctx.restoreGState()
    }

    /// The run's box: advance width × (font ascent + descent), baseline at `origin.y`.
    private func runRect(_ run: CTRun, at origin: CGPoint) -> CGRect {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
        guard CTRunGetGlyphCount(run) > 0 else { return .null }
        var first = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &first)
        return CGRect(x: origin.x + first.x, y: origin.y - ascent, width: width, height: ascent + descent)
    }

    private func addGlyphs(_ run: CTRun, _ a: RunAttributes, at origin: CGPoint, to path: CGMutablePath) {
        let count = CTRunGetGlyphCount(run)
        guard count > 0, let font = a.font else { return }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        for i in 0..<count {
            guard let glyph = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
            // Glyph outlines are y-up; the context is y-down.
            path.addPath(glyph, transform: CGAffineTransform(a: 1, b: 0, c: a.slant, d: -1,
                                                              tx: origin.x + positions[i].x,
                                                              ty: origin.y - positions[i].y))
        }
    }

    private func cgGradient(_ index: Int) -> CGGradient? {
        if let hit = gradientCache[index] { return hit }
        guard index < gradients.count else { return nil }
        let spec = gradients[index]
        guard let space = CGColorSpace(name: spec.linearGamma ? CGColorSpace.linearSRGB : CGColorSpace.sRGB)
        else { return nil }
        let colors = spec.stops.map(\.color.cgColor) as CFArray
        var locations = spec.stops.map { CGFloat(min(max($0.position, 0), 1)) }
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: &locations)
        gradientCache[index] = gradient
        return gradient
    }
}

/// The attributes `TextLayout` stores on a run.
private struct RunAttributes {
    var font: CTFont?
    var color: CGColor?
    var syntheticBold = false
    var slant: CGFloat = 0
    var underline = false
    var strikethrough = false
    var shadow: Int?
    var gradient: Int?

    init(_ run: CTRun) {
        let d = CTRunGetAttributes(run) as NSDictionary
        if let f = d[kCTFontAttributeName], CFGetTypeID(f as CFTypeRef) == CTFontGetTypeID() {
            font = (f as! CTFont)
        }
        if let c = d[RunKey.color], CFGetTypeID(c as CFTypeRef) == CGColor.typeID {
            color = (c as! CGColor)
        }
        syntheticBold = d[RunKey.bold] != nil
        slant = CGFloat((d[RunKey.slant] as? NSNumber)?.doubleValue ?? 0)
        underline = d[RunKey.underline] != nil
        strikethrough = d[RunKey.strikethrough] != nil
        shadow = (d[RunKey.shadow] as? NSNumber)?.intValue
        gradient = (d[RunKey.gradient] as? NSNumber)?.intValue
    }
}
