import Foundation

// Parses `Shape`, `Shape2`… options into drawable `ShapeItem`s — clean-room implementation of
// docs.rainmeter.net/manual/meters/shape/.
//
// Syntax (manual): `ShapeN=Type parameters | Modifier parameters | …`. Parameters are comma separated and are
// Number options (plain numbers or formulas in parentheses); modifiers may appear in any order; later modifiers
// win. Keywords are case-insensitive. `Path`, `Extend` and gradient modifiers name other options of the meter.
//
// Judgment calls where the manual is silent:
// - An unknown shape type or a shape missing a required parameter is skipped (with a log line); unknown modifiers
//   are ignored. A Fill/Stroke that cannot be parsed (bad color, missing gradient option) leaves the paint as it
//   was.
// - Coordinates are limited to ±1,000,000 and StrokeWidth to 0…10,000 so the geometry math stays finite.
// - `Fill 255,0,0` (the `Color` keyword left out) is accepted as a color.
// - Named options (Path definitions, gradients, Extend) are looked up like any meter option, so they can also come
//   from a MeterStyle and may use variables.
// - `StrokeType Center|Outer|Inner` places the stroke on, outside or inside the outline. It is not in the manual;
//   supported because some skins use it. Default Center.
// - `Combine … | Consume 0` keeps the parent and child shapes visible (default: the combined shape replaces
//   them, as the manual describes). Not in the manual.
struct ShapeParser {
    /// Looks up another option of the meter (variables already resolved).
    let lookup: (String) -> String?
    private(set) var warnings: [String] = []

    static let maxCoordinate = 1_000_000.0
    static let maxStrokeWidth = 10_000.0
    static let maxPathSegments = 10_000
    static let maxCombineDepth = 32
    /// Most operands (basic shapes) one combined shape may contain, counting repeats. A shape can be combined
    /// several times (`Shape3=Combine Shape2 | Union Shape2`), so without this limit a chain of a few dozen
    /// Combine options would build a tree with 2^N operands and hang every traversal.
    static let maxCombineOperands = 256
    static let maxDashEntries = 64

    init(lookup: @escaping (String) -> String?) {
        self.lookup = lookup
    }

    // MARK: Entry point

    mutating func items(from options: [(index: Int, value: String)]) -> [ShapeItem] {
        var raws: [Int: RawShape] = [:]
        for (index, value) in options {
            if let raw = parseShape(index: index, value) { raws[index] = raw }
        }
        var resolver = Resolver(raws: raws)
        var built: [Int: Built] = [:]
        for index in raws.keys.sorted() {
            if let b = resolver.build(index, depth: 0) { built[index] = b }
        }
        warnings += resolver.warnings
        let consumed = resolver.consumed
        var items: [ShapeItem] = []
        for index in built.keys.sorted() where !consumed.contains(index) {
            if let b = built[index] { items.append(makeItem(index: index, b)) }
        }
        return items
    }

    // MARK: Raw shapes

    struct RawShape {
        enum Kind {
            case path(ShapePath)
            case combine(parent: String, steps: [(ShapeCombineMode, String)], consume: Bool)
        }
        var kind: Kind
        var modifiers: ShapeModifiers
        var closed: Bool
    }

    private mutating func parseShape(index: Int, _ value: String) -> RawShape? {
        let label = index == 1 ? "Shape" : "Shape\(index)"
        var parts = ShapeParser.split(value, "|")
        guard !parts.isEmpty else { return nil }
        let (type, params) = ShapeParser.keyword(parts.removeFirst())
        let n = ShapeParser.numbers(params)
        let items = OptionValue.split(params, separator: ",")
        /// Required parameters must be numbers; an empty one counts as 0 (judgment: FluentDash11 draws its buttons
        /// with `Rectangle ,,100,50,8` and the author's screenshot shows them at the meter's top-left corner).
        func need(_ count: Int) -> Bool {
            let present = items.count >= count
                && (0..<count).allSatisfy { i in (i < n.count && n[i] != nil) || items[i].isEmpty }
            if present, n.prefix(count).contains(where: { $0 != nil }) { return true }
            warnings.append("\(label): \(type) needs \(count) numeric parameters")
            return false
        }
        func v(_ i: Int) -> Double? { i < n.count ? n[i] : nil }
        /// A required parameter (checked by `need`).
        func r(_ i: Int) -> Double { v(i) ?? 0 }
        func flag(_ i: Int) -> Bool { (v(i) ?? 0) != 0 }

        var subpath: ShapeSubpath
        var fillRule = ShapeFillRule.evenOdd
        switch type.lowercased() {
        case "rectangle":
            guard need(4) else { return nil }
            subpath = ShapeGeometryBuilder.rectangle(x: r(0), y: r(1), width: r(2), height: r(3),
                                                     radiusX: v(4) ?? 0, radiusY: v(5))
        case "ellipse":
            guard need(3) else { return nil }
            subpath = ShapeGeometryBuilder.ellipse(centerX: r(0), centerY: r(1), radiusX: r(2), radiusY: v(3))
        case "line":
            guard need(4) else { return nil }
            subpath = ShapeSubpath(start: ShapePoint(r(0), r(1)), segments: [ShapeSegment(.line(to: ShapePoint(r(2), r(3))))])
        case "arc":
            // StartX, StartY, EndX, EndY[, RadiusX, RadiusY, RotationAngle, SweepDirection, ArcSize, ShapeEnding]
            guard need(4) else { return nil }
            let start = ShapePoint(r(0), r(1))
            let arc = ShapeGeometryBuilder.arc(from: start, to: ShapePoint(r(2), r(3)), radiusX: v(4), radiusY: v(5),
                                               rotation: v(6) ?? 0, clockwise: !flag(7), largeArc: flag(8))
            subpath = ShapeSubpath(start: start, segments: arc.map { ShapeSegment($0) }, closed: flag(9))
        case "curve":
            // StartX, StartY, EndX, EndY, ControlX1, ControlY1[, ControlX2, ControlY2][, ShapeEnding]
            guard need(6) else { return nil }
            let start = ShapePoint(r(0), r(1)), end = ShapePoint(r(2), r(3))
            let c1 = ShapePoint(r(4), r(5))
            if n.count >= 8, let x2 = v(6), let y2 = v(7) {
                subpath = ShapeSubpath(start: start, segments: [ShapeSegment(.cubic(control1: c1, control2: ShapePoint(x2, y2), to: end))],
                                       closed: flag(8))
            } else {
                subpath = ShapeSubpath(start: start, segments: [ShapeSegment(.quadratic(control: c1, to: end))], closed: flag(6))
            }
        case "path", "path1":
            let name = params.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let definition = lookup(name) else {
                warnings.append("\(label): path definition option \"\(name)\" not found")
                return nil
            }
            guard let s = parsePath(definition, label: label) else { return nil }
            subpath = s
            if type.lowercased() == "path1" { fillRule = .nonZero }
        case "combine":
            var steps: [(ShapeCombineMode, String)] = []
            var modifiers: [String] = []
            var consume = true
            for part in parts {
                let (kw, arg) = ShapeParser.keyword(part)
                if let mode = ShapeCombineMode(rawValue: kw.lowercased()) {
                    steps.append((mode, arg.trimmingCharacters(in: .whitespaces)))
                } else if kw.lowercased() == "consume" {
                    consume = (ShapeParser.numbers(arg).first ?? nil).map { $0 != 0 } ?? true
                } else {
                    modifiers.append(part)
                }
            }
            let parent = params.trimmingCharacters(in: .whitespaces)
            guard !parent.isEmpty else {
                warnings.append("\(label): Combine needs a parent shape")
                return nil
            }
            return RawShape(kind: .combine(parent: parent, steps: steps, consume: consume),
                            modifiers: parseModifiers(modifiers, label: label), closed: true)
        default:
            warnings.append("\(label): unknown shape type \"\(type)\"")
            return nil
        }
        let path = ShapePath(subpaths: [subpath], fillRule: fillRule)
        return RawShape(kind: .path(path), modifiers: parseModifiers(parts, label: label), closed: subpath.closed)
    }

    /// `StartX, StartY | LineTo … | ArcTo … | CurveTo … | SetRoundJoin 0|1 | SetNoStroke 0|1 | ClosePath 0|1`.
    ///
    /// Manual (Path shape): LineTo/ArcTo/CurveTo take the Line/Arc/Curve parameters without the start point and
    /// without ShapeEnding; `SetRoundJoin` and `SetNoStroke` change the stroke of the segments that follow;
    /// `ClosePath 1` closes the figure. A missing or invalid start point skips the shape. `SetLineJoin` (the
    /// spelling used once in the manual's notes) is accepted as SetRoundJoin.
    private mutating func parsePath(_ definition: String, label: String) -> ShapeSubpath? {
        var parts = ShapeParser.split(definition, "|")
        guard !parts.isEmpty else {
            warnings.append("\(label): empty path definition")
            return nil
        }
        let startNumbers = ShapeParser.numbers(parts.removeFirst())
        guard startNumbers.count >= 2, let sx = startNumbers[0], let sy = startNumbers[1] else {
            warnings.append("\(label): path definition needs a start point")
            return nil
        }
        var sub = ShapeSubpath(start: ShapePoint(sx, sy))
        var stroked = true
        var roundJoin = false
        var current = sub.start
        for part in parts.prefix(ShapeParser.maxPathSegments) {
            let (kw, params) = ShapeParser.keyword(part)
            let n = ShapeParser.numbers(params)
            func v(_ i: Int) -> Double? { i < n.count ? n[i] : nil }
            func add(_ kinds: [ShapeSegmentKind]) {
                for (i, k) in kinds.enumerated() {
                    sub.segments.append(ShapeSegment(k, stroked: stroked, roundJoin: roundJoin && i == 0))
                }
                if let last = kinds.last { current = last.end }
            }
            switch kw.lowercased() {
            case "lineto":
                guard let x = v(0), let y = v(1) else { warnings.append("\(label): LineTo needs X, Y"); continue }
                add([.line(to: ShapePoint(x, y))])
            case "arcto":
                guard let x = v(0), let y = v(1) else { warnings.append("\(label): ArcTo needs X, Y"); continue }
                let arc = ShapeGeometryBuilder.arc(from: current, to: ShapePoint(x, y), radiusX: v(2), radiusY: v(3),
                                                   rotation: v(4) ?? 0, clockwise: (v(5) ?? 0) == 0, largeArc: (v(6) ?? 0) != 0)
                add(arc.isEmpty ? [.line(to: ShapePoint(x, y))] : arc)
            case "curveto":
                guard let x = v(0), let y = v(1), let cx = v(2), let cy = v(3) else {
                    warnings.append("\(label): CurveTo needs X, Y, ControlX, ControlY")
                    continue
                }
                if let cx2 = v(4), let cy2 = v(5) {
                    add([.cubic(control1: ShapePoint(cx, cy), control2: ShapePoint(cx2, cy2), to: ShapePoint(x, y))])
                } else {
                    add([.quadratic(control: ShapePoint(cx, cy), to: ShapePoint(x, y))])
                }
            // A bare command without its 0/1 value counts as 1 (judgment call: writing it shows the intent).
            case "setroundjoin", "setlinejoin":
                roundJoin = (v(0) ?? 1) != 0
            case "setnostroke":
                stroked = (v(0) ?? 1) == 0
            case "closepath":
                sub.closed = (v(0) ?? 1) != 0
            default:
                warnings.append("\(label): unknown path segment \"\(kw)\"")
            }
        }
        // SetNoStroke / SetRoundJoin hold "until they are altered again or the end of the path is reached", so the
        // closing line drawn by ClosePath uses the state in effect at the end of the definition. It is added as an
        // explicit segment to carry those flags (the figure stays closed, so the join back at the start is kept).
        if sub.closed, current.distance(to: sub.start) > 1e-9 {
            sub.segments.append(ShapeSegment(.line(to: sub.start), stroked: stroked, roundJoin: roundJoin))
        }
        return sub
    }

    // MARK: Modifiers

    /// Expands `Extend a, b` (the named options' modifiers are inserted in place; no cascading) and applies all
    /// modifiers in order, so the last one of a kind wins.
    private mutating func parseModifiers(_ parts: [String], label: String) -> ShapeModifiers {
        var expanded: [String] = []
        for part in parts {
            let (kw, params) = ShapeParser.keyword(part)
            guard kw.lowercased() == "extend" else {
                expanded.append(part)
                continue
            }
            for name in params.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
                guard let value = lookup(name) else {
                    warnings.append("\(label): Extend option \"\(name)\" not found")
                    continue
                }
                // "This functionality cannot cascade": Extend inside a named option is ignored.
                expanded += ShapeParser.split(value, "|").filter { ShapeParser.keyword($0).0.lowercased() != "extend" }
            }
        }
        var m = ShapeModifiers()
        for part in expanded { apply(part, to: &m, label: label) }
        return m
    }

    private mutating func apply(_ part: String, to m: inout ShapeModifiers, label: String) {
        let (kw, params) = ShapeParser.keyword(part)
        let n = ShapeParser.numbers(params)
        func v(_ i: Int) -> Double? { i < n.count ? n[i] : nil }
        let word = params.trimmingCharacters(in: .whitespaces).lowercased()
        switch kw.lowercased() {
        case "fill":
            if let p = parsePaint(params, label: label) { m.fill = p }
        case "stroke":
            if let p = parsePaint(params, label: label) { m.stroke = p }
        // The manual's Path section writes `Shape=Path MyPath | StrokeColor 0,255,0,255` once; accept the one-word
        // spellings as `Stroke Color` / `Fill Color` so that example works as written.
        case "strokecolor", "fillcolor":
            if let c = OptionValue.color(params) {
                if kw.lowercased() == "fillcolor" { m.fill = .color(c) } else { m.stroke = .color(c) }
            } else {
                warnings.append("\(label): invalid color \"\(params)\"")
            }
        case "strokewidth":
            if let w = v(0) { m.style.width = w.clamped(0, ShapeParser.maxStrokeWidth) }
        case "strokestartcap":
            if let c = ShapeLineCap(rawValue: word) { m.style.startCap = c }
        case "strokeendcap":
            if let c = ShapeLineCap(rawValue: word) { m.style.endCap = c }
        case "strokedashcap":
            if let c = ShapeLineCap(rawValue: word) { m.style.dashCap = c }
        case "strokelinejoin":
            // `Miter[, MiterLimit]` / `MiterOrBevel[, MiterLimit]` / `Bevel` / `Round`.
            let items = ShapeParser.split(params, ",")
            if let first = items.first, let join = ShapeLineJoin.parse(first) {
                m.style.join = join
                if items.count > 1, let limit = OptionValue.number(items[1]) { m.style.miterLimit = limit.clamped(1, 1_000_000) }
            }
        case "strokedashes":
            m.style.dashes = Array(n.prefix(ShapeParser.maxDashEntries).map { max($0 ?? 0, 0) })
        case "strokedashoffset":
            if let d = v(0) { m.style.dashOffset = d.clamped(-ShapeParser.maxCoordinate, ShapeParser.maxCoordinate) }
        case "stroketype":
            switch word {
            case "center", "centre": m.style.placement = .center
            case "outer", "outside": m.style.placement = .outer
            case "inner", "inside": m.style.placement = .inner
            default: break
            }
        case "rotate", "scale", "skew", "offset":
            if let kind = ShapeTransformKind(rawValue: kw.lowercased()) { m.transforms[kind] = n }
        case "transformorder":
            var order: [ShapeTransformKind] = []
            for name in ShapeParser.split(params, ",") {
                if let k = ShapeTransformKind(rawValue: name.lowercased()), !order.contains(k) { order.append(k) }
            }
            m.order = order + ShapeTransformKind.allCases.filter { !order.contains($0) }
        default:
            warnings.append("\(label): unknown modifier \"\(kw)\"")
        }
    }

    /// `Color c` / `LinearGradient[1] Name` / `RadialGradient[1] Name`.
    private mutating func parsePaint(_ params: String, label: String) -> ShapePaintSpec? {
        let (kind, rest) = ShapeParser.keyword(params)
        let name = rest.trimmingCharacters(in: .whitespaces)
        switch kind.lowercased() {
        case "color":
            if let c = OptionValue.color(name) { return .color(c) }
            warnings.append("\(label): invalid color \"\(name)\"")
            return nil
        case "lineargradient", "lineargradient1", "radialgradient", "radialgradient1":
            guard !name.isEmpty, let definition = lookup(name) else {
                warnings.append("\(label): gradient option \"\(name)\" not found")
                return nil
            }
            let gamma = kind.hasSuffix("1")
            var parts = ShapeParser.split(definition, "|")
            guard !parts.isEmpty else { return nil }
            let head = parts.removeFirst()
            let stops = ShapeParser.stops(parts)
            guard !stops.isEmpty else {
                warnings.append("\(label): gradient \"\(name)\" has no color stops")
                return nil
            }
            if kind.lowercased().hasPrefix("linear") {
                return .linear(angle: OptionValue.number(head) ?? 0, stops: stops, linearGamma: gamma)
            }
            let p = ShapeParser.numbers(head)
            guard p.count >= 2 else {
                warnings.append("\(label): radial gradient \"\(name)\" needs CenterX, CenterY")
                return nil
            }
            return .radial(parameters: Array(p.prefix(6)), stops: stops, linearGamma: gamma)
        default:
            if let c = OptionValue.color(params) { return .color(c) }
            warnings.append("\(label): unknown paint \"\(kind)\"")
            return nil
        }
    }

    /// `Color ; Position` items. A missing position spreads the stops evenly (judgment call).
    static func stops(_ parts: [String]) -> [ShapeGradientStop] {
        var result: [ShapeGradientStop] = []
        let items = parts.prefix(ShapeGradients.maxStops)
        for (i, item) in items.enumerated() {
            let fields = split(item, ";")
            guard let first = fields.first, let color = OptionValue.color(first) else { continue }
            let even = items.count > 1 ? Double(i) / Double(items.count - 1) : 0
            let position = fields.count > 1 ? OptionValue.number(fields[1]) ?? even : even
            result.append(ShapeGradientStop(color: color, position: position.clamped(-1_000_000, 1_000_000)))
        }
        return result
    }

    // MARK: Building items

    private func makeItem(index: Int, _ b: Built) -> ShapeItem {
        var style = b.style
        // Outside / inside only mean something for a closed outline; an open line or arc has no sides, so its
        // stroke stays centered (otherwise it would be drawn twice as wide and unclipped).
        if !b.closed { style.placement = .center }
        let bounds: ShapeRect
        var plan: ShapeStrokePlan?
        switch b.geometry {
        case .path(let path):
            bounds = ShapeMath.bounds(of: path) ?? ShapeRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
            plan = ShapeStroker.plan(for: path, style: style)
        case .combined:
            bounds = Resolver.conservativeBounds(b.geometry) ?? ShapeRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        }
        var visual = bounds
        if style.width > 0 {
            switch style.placement {
            case .inner:
                break
            case .center, .outer:
                let grow = style.placement == .center ? style.width / 2 : style.width
                if let plan, let r = ShapeStroker.bounds(of: plan) {
                    visual = visual.union(r)
                } else {
                    visual = visual.union(bounds.insetBy(-grow))
                }
            }
        }
        let strokeGrow = style.placement == .center ? style.width / 2 : style.placement == .outer ? style.width : 0
        return ShapeItem(index: index, geometry: b.geometry, closed: b.closed,
                         fill: b.fill.resolve(in: b.localBounds),
                         stroke: style.width > 0 ? b.stroke.resolve(in: b.localBounds.insetBy(-strokeGrow)) : .none,
                         strokeStyle: style, strokePlan: plan, paintTransform: b.transform,
                         bounds: bounds, visualBounds: visual)
    }

    struct Built {
        var geometry: ShapeGeometry
        /// Bounds before the shape's own transforms (the space gradients are placed in).
        var localBounds: ShapeRect
        var transform: ShapeTransform
        var closed: Bool
        var fill: ShapePaintSpec
        var stroke: ShapePaintSpec
        var style: ShapeStrokeStyle
        /// Basic shapes in `geometry` (1 for a plain shape; repeats counted).
        var operands = 1
    }

    /// Builds shapes in any order (Combine may name shapes defined after it), detecting cycles.
    struct Resolver {
        let raws: [Int: RawShape]
        var memo: [Int: Built?] = [:]
        var visiting: Set<Int> = []
        var consumed: Set<Int> = []
        var warnings: [String] = []

        init(raws: [Int: RawShape]) {
            self.raws = raws
        }

        mutating func build(_ index: Int, depth: Int) -> Built? {
            if let cached = memo[index] { return cached }
            guard let raw = raws[index], depth < ShapeParser.maxCombineDepth, !visiting.contains(index) else {
                if visiting.contains(index) { warnings.append("Shape\(index == 1 ? "" : String(index)): Combine cycle") }
                return nil
            }
            visiting.insert(index)
            defer { visiting.remove(index) }
            let result: Built?
            switch raw.kind {
            case .path(let path):
                let local = ShapeMath.bounds(of: path) ?? ShapeRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
                let t = raw.modifiers.transform(bounds: local)
                let m = raw.modifiers
                result = Built(geometry: .path(path.transformed(t)), localBounds: local, transform: t, closed: raw.closed,
                               fill: m.fill ?? (raw.closed ? .color(.white) : .none),
                               stroke: m.stroke ?? .color(.black), style: m.style)
            case .combine(let parentName, let steps, let consume):
                result = buildCombine(index, raw, parentName, steps, consume, depth: depth)
            }
            memo[index] = result
            return result
        }

        /// Manual (Combine): the parent's attribute modifiers are inherited and those of the children and of the
        /// combined shape are ignored; every operand's own transforms are applied before combining and the combined
        /// shape's transforms after; open operands are closed first; the combined shape replaces its operands.
        private mutating func buildCombine(_ index: Int, _ raw: RawShape, _ parentName: String,
                                           _ steps: [(ShapeCombineMode, String)], _ consume: Bool, depth: Int) -> Built? {
            let label = index == 1 ? "Shape" : "Shape\(index)"
            guard let parentIndex = Resolver.shapeIndex(parentName), let parent = build(parentIndex, depth: depth + 1) else {
                warnings.append("\(label): Combine parent \"\(parentName)\" is not a valid shape")
                return nil
            }
            var used = [parentIndex]
            var combineSteps: [ShapeCombineStep] = []
            var operands = parent.operands
            for (mode, name) in steps {
                guard let childIndex = Resolver.shapeIndex(name), childIndex != index, let child = build(childIndex, depth: depth + 1) else {
                    warnings.append("\(label): Combine child \"\(name)\" is not a valid shape")
                    continue
                }
                operands += child.operands
                guard operands <= ShapeParser.maxCombineOperands else {
                    warnings.append("\(label): Combine has more than \(ShapeParser.maxCombineOperands) shapes")
                    return nil
                }
                used.append(childIndex)
                combineSteps.append(ShapeCombineStep(mode: mode, geometry: Resolver.closed(child.geometry)))
            }
            let local = ShapeGeometry.combined(Resolver.closed(parent.geometry), combineSteps)
            let localBounds = Resolver.conservativeBounds(local) ?? ShapeRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
            let t = raw.modifiers.transform(bounds: localBounds)
            if consume { consumed.formUnion(used) }
            return Built(geometry: local.transformed(t), localBounds: localBounds, transform: t, closed: true,
                         fill: parent.fill, stroke: parent.stroke, style: parent.style, operands: operands)
        }

        static func closed(_ g: ShapeGeometry) -> ShapeGeometry {
            if case .path(let p) = g { return .path(p.closedCopy) }
            return g
        }

        /// `Shape` → 1, `ShapeN` → N (case-insensitive; `Shape1` is accepted too).
        static func shapeIndex(_ name: String) -> Int? {
            let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard lower.hasPrefix("shape") else { return nil }
            let digits = lower.dropFirst(5)
            if digits.isEmpty { return 1 }
            guard digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n >= 1 else { return nil }
            return n
        }

        /// Bounds that contain the combined region: the union's box for Union/XOR, the overlap of the boxes for
        /// Intersect, the parent's box for Exclude. Nil when the region is certainly empty.
        static func conservativeBounds(_ g: ShapeGeometry) -> ShapeRect? {
            switch g {
            case .path(let p):
                return ShapeMath.bounds(of: p)
            case .combined(let base, let steps):
                var r = conservativeBounds(base)
                for step in steps {
                    let b = conservativeBounds(step.geometry)
                    switch step.mode {
                    case .union, .xor:
                        if let b { r = r.map { $0.union(b) } ?? b }
                    case .intersect:
                        if let current = r, let b { r = current.intersection(b) } else { r = nil }
                    case .exclude:
                        break
                    }
                }
                return r
            }
        }
    }

    // MARK: Text helpers

    /// Splits at `separator` outside parentheses; trims items and drops empty ones.
    static func split(_ s: String, _ separator: Character) -> [String] {
        OptionValue.split(s, separator: separator).filter { !$0.isEmpty }
    }

    /// Leading keyword (ASCII letters and digits) and the rest of the text.
    static func keyword(_ s: String) -> (String, String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        let end = t.firstIndex { !($0.isASCII && ($0.isLetter || $0.isNumber)) } ?? t.endIndex
        return (String(t[..<end]), String(t[end...]).trimmingCharacters(in: .whitespaces))
    }

    /// Comma-separated Number parameters; `*` or an empty item means "default" (nil), as does an unreadable one.
    /// Trailing empty items are dropped. Values are limited to ±maxCoordinate.
    static func numbers(_ s: String) -> [Double?] {
        var items = OptionValue.split(s, separator: ",")
        while let last = items.last, last.isEmpty { items.removeLast() }
        return items.prefix(64).map { item in
            item == "*" || item.isEmpty ? nil : OptionValue.number(item).map { $0.clamped(-maxCoordinate, maxCoordinate) }
        }
    }
}

enum ShapeTransformKind: String, CaseIterable {
    case rotate, scale, skew, offset
}

/// Modifiers of one shape (the last of each kind wins).
struct ShapeModifiers {
    var fill: ShapePaintSpec?
    var stroke: ShapePaintSpec?
    var style = ShapeStrokeStyle()
    /// Raw parameters of Rotate / Scale / Skew / Offset.
    var transforms: [ShapeTransformKind: [Double?]] = [:]
    /// `TransformOrder`, completed with the missing kinds in the default order Rotate, Scale, Skew, Offset.
    var order = ShapeTransformKind.allCases

    /// Manual (Transform Modifiers): `Rotate Angle[, AnchorX, AnchorY]`, `Scale X, Y[, AnchorX, AnchorY]`,
    /// `Skew X, Y[, AnchorX, AnchorY]`, `Offset X, Y`, applied in `TransformOrder`. Anchors default to the center
    /// of the shape and are otherwise relative to its top-left corner.
    ///
    /// Judgment calls: every anchor refers to the shape's untransformed bounds (not the result of earlier
    /// transforms); each missing parameter takes its documented default (Scale 1, Skew 0, Offset 0), so
    /// `Scale 2` only stretches X; an anchor given for one axis only uses the center for the other.
    func transform(bounds: ShapeRect) -> ShapeTransform {
        var t = ShapeTransform.identity
        for kind in order {
            guard let n = transforms[kind] else { continue }
            func v(_ i: Int) -> Double? { i < n.count ? n[i] : nil }
            func anchor(_ i: Int) -> ShapePoint {
                ShapePoint(v(i).map { bounds.minX + $0 } ?? bounds.center.x, v(i + 1).map { bounds.minY + $0 } ?? bounds.center.y)
            }
            switch kind {
            case .rotate:
                t = t.then(.rotation(degrees: v(0) ?? 0, around: anchor(1)))
            case .scale:
                t = t.then(.scale(v(0) ?? 1, v(1) ?? 1, around: anchor(2)))
            case .skew:
                t = t.then(.skew(degreesX: v(0) ?? 0, degreesY: v(1) ?? 0, around: anchor(2)))
            case .offset:
                t = t.then(.translation(v(0) ?? 0, v(1) ?? 0))
            }
        }
        return t
    }
}

extension ShapeLineJoin {
    static func parse(_ s: String) -> ShapeLineJoin? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "miter": return .miter
        case "bevel": return .bevel
        case "round": return .round
        // "MeterOrBevel" is how the manual spells it once (StrokeLineJoin notes).
        case "miterorbevel", "meterorbevel": return .miterOrBevel
        default: return nil
        }
    }
}
