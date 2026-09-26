import Foundation

// MARK: - Snapping

/// Smart guides for dragging a meter on the editor canvas: the moving rectangle's left / center / right (and top /
/// middle / bottom) snap to the same lines of the other meters and of the skin when they are within `threshold`.
public enum EditorSnapping {
    public struct Guide: Equatable {
        public enum Axis: Equatable { case vertical, horizontal }
        public var axis: Axis
        /// X of a vertical guide, Y of a horizontal one (skin coordinates).
        public var position: Double
    }

    public struct Result: Equatable {
        /// Correction to add to the proposed movement.
        public var dx: Double
        public var dy: Double
        public var guides: [Guide]
    }

    /// Snaps `moving` (already at its proposed place) to `targets` (other meters and the skin bounds).
    public static func snap(_ moving: SkinRect, to targets: [SkinRect], threshold: Double) -> Result {
        func lines(_ r: SkinRect, vertical: Bool) -> [Double] {
            vertical ? [r.x, r.x + r.width / 2, r.x + r.width] : [r.y, r.y + r.height / 2, r.y + r.height]
        }
        func best(vertical: Bool) -> (delta: Double, position: Double)? {
            var found: (delta: Double, position: Double)?
            for target in targets {
                for t in lines(target, vertical: vertical) {
                    for m in lines(moving, vertical: vertical) {
                        let d = t - m
                        if abs(d) <= threshold, found.map({ abs(d) < abs($0.delta) }) ?? true { found = (d, t) }
                    }
                }
            }
            return found
        }
        var result = Result(dx: 0, dy: 0, guides: [])
        if let v = best(vertical: true) {
            result.dx = v.delta
            result.guides.append(Guide(axis: .vertical, position: v.position))
        }
        if let h = best(vertical: false) {
            result.dy = h.delta
            result.guides.append(Guide(axis: .horizontal, position: h.position))
        }
        return result
    }
}

// MARK: - Colors

/// Writes a color back in the notation the skin used: hex stays hex (`RRGGBB[AA]`), decimal stays decimal
/// (`R,G,B[,A]`). Alpha is written when the original had it or when it is not opaque.
public enum ColorText {
    public static func format(_ color: RGBA, like original: String?) -> String {
        let r = component(color.r), g = component(color.g), b = component(color.b), a = component(color.a)
        let t = IniSyntax.trim(original ?? "")
        let isHex = !t.isEmpty && !t.contains(",") && OptionValue.color(t) != nil
        let hadAlpha = isHex ? t.count == 8 : t.split(separator: ",", omittingEmptySubsequences: false).count >= 4
        let withAlpha = hadAlpha || a != 255
        if isHex {
            let lower = t == t.lowercased() && t != t.uppercased()
            var s = String(format: "%02X%02X%02X", r, g, b) + (withAlpha ? String(format: "%02X", a) : "")
            if lower { s = s.lowercased() }
            return s
        }
        return "\(r),\(g),\(b)" + (withAlpha ? ",\(a)" : "")
    }

    private static func component(_ v: Double) -> Int { Int(min(max(v, 0), 255).rounded()) }
}

// MARK: - Undo

/// One undoable editor action: the bytes of every file it changed, before and after. Undo and redo put the other
/// bytes back only when the file still holds what the editor left there, so a change made meanwhile in another
/// editor is never overwritten.
public struct EditorFileChange: Equatable {
    public var file: URL
    public var before: Data
    public var after: Data

    public init(file: URL, before: Data, after: Data) {
        self.file = file
        self.before = before
        self.after = after
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case changedElsewhere(URL)
        case unreadable(URL)

        public var description: String {
            switch self {
            case .changedElsewhere(let url): return "\(url.lastPathComponent) was changed in another app"
            case .unreadable(let url): return "cannot read \(url.lastPathComponent)"
            }
        }
    }

    /// Records the files `body` changes. Files that end up unchanged are left out.
    public static func record(_ files: [URL], _ body: () throws -> Void) rethrows -> [EditorFileChange] {
        var unique: [URL] = []
        // Symlinks resolved: the edit (IniWriter) changes the target, and so must undo.
        for f in files.map({ $0.standardizedFileURL.resolvingSymlinksInPath() }) where !unique.contains(f) {
            unique.append(f)
        }
        let before = unique.map { (try? Data(contentsOf: $0)) ?? Data() }
        try body()
        return zip(unique, before).compactMap { url, old in
            let new = (try? Data(contentsOf: url)) ?? Data()
            return new == old ? nil : EditorFileChange(file: url, before: old, after: new)
        }
    }

    /// Puts `before` back (undo) or `after` back (redo). All files are checked first; nothing is written when one
    /// of them was changed elsewhere.
    public static func restore(_ changes: [EditorFileChange], undo: Bool) throws {
        for c in changes {
            guard let current = try? Data(contentsOf: c.file) else { throw Failure.unreadable(c.file) }
            if current != (undo ? c.after : c.before) { throw Failure.changedElsewhere(c.file) }
        }
        for c in changes { try (undo ? c.before : c.after).write(to: c.file, options: .atomic) }
    }
}
