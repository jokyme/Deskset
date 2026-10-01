import DesksetDraw

/// The complement of known device rectangles, without raster coverage or a layer partition policy.
/// Work follows hole edges, not individual pixel rows, so large validated viewports remain geometric values.
package enum RectangleComplement {
    private struct Span: Hashable {
        let minX: Int
        let maxX: Int
    }

    package static func slices(in viewport: InkBounds.DeviceRect,
                               excluding holes: [InkBounds.DeviceRect]) -> [InkBounds.DeviceRect] {
        guard !viewport.isEmpty else { return [] }
        let clipped = holes.compactMap { intersection($0, viewport) }
        guard !clipped.isEmpty else { return [viewport] }

        var edges = Set([viewport.minY, viewport.maxY])
        for hole in clipped {
            edges.insert(hole.minY)
            edges.insert(hole.maxY)
        }
        let bands = edges.sorted()
        var finished: [InkBounds.DeviceRect] = []
        var open: [Span: InkBounds.DeviceRect] = [:]
        for band in bands.indices.dropLast() {
            let y0 = bands[band], y1 = bands[band + 1]
            precondition(y0 < y1, "Distinct row-band edges must increase")
            let covering = clipped.filter { $0.minY < y1 && $0.maxY > y0 }
                .sorted { ($0.minX, $0.maxX) < ($1.minX, $1.maxX) }
            var spans: [Span] = []
            var cursor = viewport.minX
            for hole in covering {
                if cursor < hole.minX { spans.append(Span(minX: cursor, maxX: hole.minX)) }
                cursor = max(cursor, hole.maxX)
            }
            if cursor < viewport.maxX { spans.append(Span(minX: cursor, maxX: viewport.maxX)) }

            var next: [Span: InkBounds.DeviceRect] = [:]
            for span in spans {
                precondition(next[span] == nil, "Free spans in a row band must be unique")
                if let previous = open.removeValue(forKey: span) {
                    guard previous.maxY == y0 else {
                        preconditionFailure("An open slice must end at the adjacent row band")
                    }
                    next[span] = checkedBounds(span.minX, previous.minY, span.maxX, y1)
                } else {
                    next[span] = checkedBounds(span.minX, y0, span.maxX, y1)
                }
            }
            // Only matching X edges continue. Other spans may change independently in the same row band.
            finished.append(contentsOf: open.values)
            open = next
        }
        finished.append(contentsOf: open.values)
        return finished.sorted {
            ($0.minY, $0.minX, $0.maxY, $0.maxX) < ($1.minY, $1.minX, $1.maxY, $1.maxX)
        }
    }

    private static func intersection(_ rectangle: InkBounds.DeviceRect, _ viewport: InkBounds.DeviceRect)
        -> InkBounds.DeviceRect? {
        let x0 = max(rectangle.minX, viewport.minX), y0 = max(rectangle.minY, viewport.minY)
        let x1 = min(rectangle.maxX, viewport.maxX), y1 = min(rectangle.maxY, viewport.maxY)
        guard x0 < x1, y0 < y1 else { return nil }
        return checkedBounds(x0, y0, x1, y1)
    }

    /// Every edge remains inside the same validated viewport; spans are positive and representable without area.
    /// Invalid internal bounds are an invariant failure, never a reason to silently lose a slice.
    private static func checkedBounds(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> InkBounds.DeviceRect {
        guard x0 < x1, y0 < y1,
              let bounds = InkBounds.DeviceRect(minX: x0, minY: y0, maxX: x1, maxY: y1) else {
            preconditionFailure("Complement slices must fit within the validated viewport")
        }
        return bounds
    }
}
