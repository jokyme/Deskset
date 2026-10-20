import Foundation

/// One shaped insertion position in UTF-16 coordinates; x is relative to the input's content box.
public struct TextEditCaret: Equatable, Sendable {
    public var offset: Int
    public var x: Double

    public init(offset: Int, x: Double) { self.offset = offset; self.x = x }
}

/// A shaped character cell. Logical neighbors may occupy disjoint visual pieces in bidirectional text.
public struct TextEditCell: Equatable, Sendable {
    public var range: Range<Int>
    public var bounds: SkinRect

    public init(range: Range<Int>, bounds: SkinRect) { self.range = range; self.bounds = bounds }
}

/// A visual line, including its terminating newline when present. Caret stops omit newline and surrogate interiors.
public struct TextEditLine: Equatable, Sendable {
    public var range: Range<Int>
    public var bounds: SkinRect
    public var caretStops: [TextEditCaret]
    public var isSoftWrap: Bool
    public var selectionCells: [TextEditCell]?
    /// Visual insertion stops resolved by the shaping service's hit testing (including bidi boundary affinity).
    public var hitStops: [TextEditCaret]?

    public init(range: Range<Int>, bounds: SkinRect, caretStops: [TextEditCaret], isSoftWrap: Bool,
                selectionCells: [TextEditCell]? = nil, hitStops: [TextEditCaret]? = nil) {
        self.range = range
        self.bounds = bounds
        self.caretStops = caretStops
        self.isSoftWrap = isSoftWrap
        self.selectionCells = selectionCells
        self.hitStops = hitStops
    }
}

/// Pure, captured editing geometry. It crosses the drawing-service boundary without retaining CoreText objects.
/// Coordinates start at the content box's top-left, before scrolling; indices are displayed-text UTF-16 offsets.
public struct TextEditLayout: Equatable, Sendable {
    public var lines: [TextEditLine]
    public var contentSize: SkinSize
    public var viewportSize: SkinSize

    public init(lines: [TextEditLine], contentSize: SkinSize, viewportSize: SkinSize) {
        self.lines = lines
        self.contentSize = contentSize
        self.viewportSize = viewportSize
    }

    public func lineIndex(at offset: Int, preferredLine: Int? = nil) -> Int {
        guard !lines.isEmpty else { return 0 }
        if let preferredLine, lines.indices.contains(preferredLine),
           lines[preferredLine].caretStops.contains(where: { $0.offset == offset }) { return preferredLine }
        for index in lines.indices {
            let line = lines[index]
            if offset < line.range.upperBound { return index }
            if offset == line.range.upperBound {
                if index + 1 < lines.count, lines[index + 1].range.lowerBound == offset { continue }
                return index
            }
        }
        return lines.count - 1
    }

    public func caretRect(at offset: Int, preferredLine: Int? = nil) -> SkinRect {
        guard !lines.isEmpty else { return SkinRect(width: 1) }
        let line = lines[lineIndex(at: offset, preferredLine: preferredLine)]
        let stop = line.caretStops.min { abs($0.offset - offset) < abs($1.offset - offset) }
        return SkinRect(x: stop?.x ?? line.bounds.x, y: line.bounds.y, width: 1, height: line.bounds.height)
    }

    public func hitTest(_ point: SkinPoint) -> Int {
        guard !lines.isEmpty else { return 0 }
        let index = lines.firstIndex { point.y < $0.bounds.maxY } ?? lines.count - 1
        return offset(onLine: index, preferredX: point.x)
    }

    public func offset(onLine index: Int, preferredX: Double) -> Int {
        guard !lines.isEmpty else { return 0 }
        let line = lines[min(max(index, 0), lines.count - 1)]
        return (line.hitStops ?? line.caretStops).min { abs($0.x - preferredX) < abs($1.x - preferredX) }?.offset
            ?? line.range.lowerBound
    }

    public func selectionRects(in selection: Range<Int>) -> [SkinRect] {
        guard !selection.isEmpty else { return [] }
        var result: [SkinRect] = []
        for line in lines {
            let start = max(selection.lowerBound, line.range.lowerBound)
            let end = min(selection.upperBound, line.range.upperBound)
            guard start < end else { continue }
            // Adjacent shaped caret cells also preserve disjoint visual pieces in bidirectional text.
            var pieces: [SkinRect] = []
            let stops = line.caretStops.sorted { $0.offset < $1.offset }
            if let cells = line.selectionCells {
                pieces = cells.filter { $0.range.lowerBound < end && $0.range.upperBound > start }.map(\.bounds)
            } else {
                for pair in zip(stops, stops.dropFirst()) where pair.0.offset < end && pair.1.offset > start {
                    pieces.append(SkinRect(x: min(pair.0.x, pair.1.x), y: line.bounds.y,
                                           width: max(abs(pair.1.x - pair.0.x), 1), height: line.bounds.height))
                }
            }
            if let last = stops.last, end > last.offset {
                // A selected newline occupies a caret-width cell even though it has no painted glyph.
                pieces.append(SkinRect(x: last.x, y: line.bounds.y, width: 1, height: line.bounds.height))
            }
            for rect in pieces.sorted(by: { $0.x < $1.x }) {
                if let last = result.last, last.y == rect.y, rect.x <= last.maxX + 0.01 {
                    result[result.count - 1].width = max(last.maxX, rect.maxX) - last.x
                } else { result.append(rect) }
            }
        }
        return result
    }

    /// A deterministic host-less layout for model-only execution. Native drawing hosts supply shaped geometry.
    public static func fallback(text: String, style: TextStyle, viewport: SkinRect,
                                multiline: Bool) -> TextEditLayout {
        let height = max(TextStyle.pixelSize(points: style.fontSize), 1)
        let cell = max(height * 0.5, 1)
        let available = max(viewport.width, cell)
        var lines: [TextEditLine] = []
        var start = 0, offset = 0, y = 0.0, x = 0.0
        var stops = [TextEditCaret(offset: 0, x: 0)]
        func appendLine(_ end: Int, soft: Bool) {
            lines.append(TextEditLine(range: start..<end,
                                      bounds: SkinRect(y: y, width: x, height: height),
                                      caretStops: stops, isSoftWrap: soft))
            start = end; y += height; x = 0
            stops = [TextEditCaret(offset: end, x: 0)]
        }
        for character in text {
            let length = String(character).utf16.count
            if character.isNewline {
                offset += length
                appendLine(offset, soft: false)
            } else {
                if multiline, style.wrap, x > 0, x + cell > available { appendLine(offset, soft: true) }
                x += cell; offset += length
                stops.append(TextEditCaret(offset: offset, x: x))
            }
        }
        appendLine(offset, soft: false)
        return TextEditLayout(lines: lines,
                              contentSize: SkinSize(width: lines.map(\.bounds.maxX).max() ?? 0, height: y),
                              viewportSize: SkinSize(width: max(viewport.width, 0), height: max(viewport.height, 0)))
    }
}
