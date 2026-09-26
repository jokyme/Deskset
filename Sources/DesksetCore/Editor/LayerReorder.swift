import Foundation

/// The reorder guard of the layer list (docs/editor-friendly.md §5.2): changing the drawing order moves a layer in the
/// file, and some positions depend on file order — `r` / `R` place a meter relative to the meter before it (manual:
/// General Meter Options → X, Y), and `[Meter:X]` reads another meter that may no longer be laid out first. So that
/// nothing moves on screen, those positions are written as the fixed numbers they have now, in the same undo step.
///
/// A block that moves together (a run of repeated layers) keeps its inner chain: only the first member gets a new
/// previous meter.
public enum LayerReorder {
    /// One position to write: `key` (`X` or `Y`) of meter `section`, into the meter's own section.
    public struct Edit: Equatable {
        public var section: String
        public var key: String
        public var value: String

        public init(section: String, key: String, value: String) {
            self.section = section
            self.key = key
            self.value = value
        }
    }

    /// The meters in their new file order when `moving` (a block, in its current order) goes right before `before`
    /// (nil: after the last meter, i.e. to the front). Unchanged when `before` is one of the moving meters.
    public static func order(of names: [String], moving: [String], before: String?) -> [String] {
        let movingSet = Set(moving.map { $0.lowercased() })
        if let before, movingSet.contains(before.lowercased()) { return names }
        let block = names.filter { movingSet.contains($0.lowercased()) }
        var rest = names.filter { !movingSet.contains($0.lowercased()) }
        if let before, let i = rest.firstIndex(where: { $0.caseInsensitiveCompare(before) == .orderedSame }) {
            rest.insert(contentsOf: block, at: i)
        } else {
            rest.append(contentsOf: block)
        }
        return rest
    }

    /// The positions to fix when `moving` goes right before `before` (nil: to the front): X or Y of every meter placed
    /// relative to the meter before it whose previous meter changes, and of every meter whose position reads a meter
    /// that then comes after it instead of before (or the other way round). Each gets its current value, so every
    /// frame stays where it is. Meters in a container are relative to the content before them in that container.
    public static func fixups(skin: Skin, moving: [String], to before: String?) -> [Edit] {
        let old = skin.meters.map(\.name)
        let new = order(of: old, moving: moving, before: before)
        guard new.map({ $0.lowercased() }) != old.map({ $0.lowercased() }) else { return [] }
        func index(_ order: [String]) -> [String: Int] {
            var result: [String: Int] = [:]
            for (i, name) in order.enumerated() { result[name.lowercased()] = i }
            return result
        }
        let oldIndex = index(old), newIndex = index(new)
        /// The meter placed before `m` in `order` (the previous meter in the same container, or outside containers).
        func previous(_ m: Meter, in order: [String]) -> String? {
            guard let i = order.firstIndex(where: { $0.caseInsensitiveCompare(m.name) == .orderedSame }) else { return nil }
            let container = m.container?.name.lowercased()
            for name in order[..<i].reversed() {
                guard let other = skin.meter(named: name) else { continue }
                if other.container?.name.lowercased() == container { return other.name.lowercased() }
            }
            return nil
        }
        var edits: [Edit] = []
        for m in skin.meters {
            let newPrevious = previous(m, in: new) != previous(m, in: old)
            for (key, position, anchor, origin) in [("X", m.xPosition, m.anchorX, m.container?.frame.x ?? 0),
                                                    ("Y", m.yPosition, m.anchorY, m.container?.frame.y ?? 0)] {
                var fix = newPrevious && position.mode != .absolute
                if !fix {
                    let raw = m.rawOption(key) ?? ""
                    for name in LayerReferences.bracketNames(in: raw) {
                        guard let other = skin.meter(named: name), other !== m,
                              let o1 = oldIndex[other.name.lowercased()], let o2 = newIndex[other.name.lowercased()],
                              let m1 = oldIndex[m.name.lowercased()], let m2 = newIndex[m.name.lowercased()] else { continue }
                        if (o1 < m1) != (o2 < m2) { fix = true }
                    }
                }
                if fix { edits.append(Edit(section: m.name, key: key, value: GeometryEdit.format(anchor - origin))) }
            }
        }
        return edits
    }
}
