import Foundation

// Formatting for the editor, built on `Desk.format` (§3.8): the whole file, or the part of it a selection covers.

extension DeskSnapshot {
    /// The edits that bring the open file to the canonical style, sorted and not overlapping. Empty when the file is
    /// already formatted, or when formatting could not keep its tokens (`Desk.format` then gives nothing).
    public func formatDocument() -> [DeskTextEditU16] {
        formatEdits8().map { DeskTextEditU16(range: index.range(utf8: $0.range), newText: $0.replacement) }
    }

    /// The formatting edits of a selection: the selection is widened to the whole statements it touches and then to
    /// whole lines (`formattingRange(for:)`), and the edits of `formatDocument` that meet that range are kept.
    /// Formatting only changes the space between tokens, so any subset of its edits keeps the code's meaning.
    public func formatRange(_ range: DeskRange) -> [DeskTextEditU16] {
        let widened = index.utf8Range(of: formattingRange(for: range))
        return formatEdits8()
            .filter { $0.range.lowerBound <= widened.upperBound && $0.range.upperBound >= widened.lowerBound }
            .map { DeskTextEditU16(range: index.range(utf8: $0.range), newText: $0.replacement) }
    }

    /// `formatRange` for a text view's selection (nil range: nothing).
    public func formatRange(_ nsRange: NSRange) -> [DeskTextEditU16] {
        guard let range = index.range(nsRange) else { return [] }
        return formatRange(range)
    }

    /// The range `formatRange` works on: from the start of the line of the first statement the selection touches to
    /// the end (before the line break) of the line of the last. The statements are the innermost statements or
    /// top-level blocks whose text holds the selection's first and last characters that are not blanks; a cursor
    /// touches the rest of its line. A selection that ends at the start of a line does not take that line.
    public func formattingRange(for range: DeskRange) -> DeskRange {
        let span = index.utf8Range(of: range)
        let bytes = index.bytes
        var first = span.lowerBound
        var last = span.isEmpty ? index.utf8ContentEnd(ofLine: index.line(ofUTF8: first)) : span.upperBound
        func isBlank(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
        while first < last, isBlank(bytes[first]) { first += 1 }
        while last > first, isBlank(bytes[last - 1]) { last -= 1 }
        var lower = span.lowerBound
        var upper = span.upperBound
        if first < last {
            for probe in [first, index.clampedUTF8(last - 1)] {
                guard let statement = innermostStatement(at: probe) else { continue }
                lower = min(lower, statement.lowerBound)
                upper = max(upper, statement.upperBound)
            }
        }
        let firstLine = index.line(ofUTF8: lower)
        let lastLine = max(firstLine, index.line(ofUTF8: upper > lower ? upper - 1 : upper))
        let start = index.utf8Range(ofLine: firstLine).lowerBound
        return index.range(utf8: start..<max(start, index.utf8ContentEnd(ofLine: lastLine)))
    }

    /// `Desk.format`'s edits of the open file (UTF-8), computed once.
    func formatEdits8() -> [TextEdit] {
        caches.formatEdits.value {
            Desk.format(tree, options: options.format).sorted {
                ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound)
            }
        }
    }

    /// The text range (UTF-8, trivia excluded) of the innermost statement or top-level block whose text holds the
    /// byte at `offset`.
    func innermostStatement(at offset: Int) -> Range<Int>? {
        var current = tree.rootNode
        var found: Range<Int>?
        while true {
            var next: PositionedNode?
            for child in current.children {
                guard case .node(let node) = child, node.range.contains(offset) else { continue }
                // Leading trivia belongs to the node's first token but not to its text.
                if node.quickTextRange.contains(offset) { next = node }
                break
            }
            guard let node = next else { return found }
            if node.kind.isStatement || node.kind.isTopLevelBlock || node.kind == .strayStatement {
                found = node.quickTextRange
            }
            current = node
        }
    }
}
