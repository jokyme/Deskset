import Foundation

// The Shape meter as the editor sees it: one value object per `Shape` / `ShapeN` option (`ShapeSpec`), per named
// gradient option (`GradientSpec`) and per path definition option (`PathSpec`), each parsed without resolving
// anything and written back as text. The grammar is the engine's (`ShapeParser`, `ShapeTypes`, `ShapeGradients`,
// all clean-room from docs.rainmeter.net/manual/meters/shape/); the difference is that values stay *as written*:
// parameters are kept as their text (`(#Size# / 2)`, `#Box#`, `*`), so the editor can show formulas and variables as
// pills and never loses a token.
//
// Text rules (the same for all three value types):
// - Parsing splits at `|` outside parentheses (like the engine), trims every part and drops empty parts.
// - `normalized(_:)` is the *whitespace normalisation of separators*: parts joined with " | "; inside a part, outside
//   parentheses, whitespace next to `,` is removed (except after a leading keyword: `Rectangle ,,100` keeps its space,
//   as the canonical form writes it) and any other run of whitespace becomes one space (gradient stops also get
//   " ; " between color and position). Text inside parentheses is never touched.
// - `text` of a value that was parsed and not changed equals `normalized(input)`: every part keeps its spelling
//   (`fill color`, `FillColor`, `Fill 255,0,0`, `StrokeType Centre` stay as written). A part that was changed, added
//   or reordered next to others keeps its spelling when its value is still the same; a changed part is written in
//   the canonical form `Keyword a,b,c` (`Rectangle 0,0,100,40,6`, `Fill Color 255,0,0`, `StrokeLineJoin Miter,4`).
// - `parse(text)` of any value gives back an equal value (`==` compares the parsed content, not the spellings).

// MARK: - Shared text helpers

enum ShapeText {
    /// Splits at `separator` outside parentheses, trims every item and drops empty ones (the engine's `split`).
    static func parts(_ s: String, _ separator: Character) -> [String] {
        OptionValue.split(s, separator: separator).filter { !$0.isEmpty }
    }

    /// Comma-separated items outside parentheses, trimmed, empties kept (`,,100` → ["", "", "100"]); [] for "".
    static func items(_ s: String) -> [String] {
        s.isEmpty ? [] : OptionValue.split(s, separator: ",")
    }

    /// The leading keyword (ASCII letters and digits) and the trimmed rest — the engine's `ShapeParser.keyword`.
    static func keyword(_ s: String) -> (String, String) { ShapeParser.keyword(s) }

    /// One part (between `|`) with its whitespace normalised: outside parentheses, whitespace next to a comma is
    /// removed and every other run of whitespace becomes a single space; leading / trailing whitespace goes. The
    /// whitespace after a leading keyword (a word starting with a letter) always becomes one space, so an empty
    /// first parameter keeps the canonical spelling (`Rectangle ,,100,50`, not `Rectangle,,100,50`).
    static func normalizedPart(_ part: String) -> String {
        var out = ""
        var depth = 0
        var pendingSpace = false
        var keywordOnly = true   // `out` is a word starting with a letter (nothing else yet)
        for ch in part {
            let isSpace = ch.unicodeScalars.allSatisfy { OptionText.isSpace($0) }
            if depth == 0 && isSpace {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                pendingSpace = false
                let afterKeyword = keywordOnly && out.first?.isLetter == true
                if !out.isEmpty && (afterKeyword || (out.last != "," && ch != ",")) {
                    out.append(" ")
                    keywordOnly = false
                }
            }
            if ch == "(" { depth += 1 } else if ch == ")" && depth > 0 { depth -= 1 }
            if !(ch.isASCII && (ch.isLetter || ch.isNumber)) { keywordOnly = false }
            out.append(ch)
        }
        return out
    }

    /// `normalizedPart` for every `|` part, empties dropped, joined with " | ".
    static func normalized(_ raw: String) -> String {
        parts(raw, "|").map(normalizedPart).filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// `Keyword` or `Keyword arguments`.
    static func join(_ keyword: String, _ arguments: String) -> String {
        arguments.isEmpty ? keyword : keyword + " " + arguments
    }

    /// Parameters with trailing absent (nil) ones dropped and inner absent ones written as `*` (the engine's "use
    /// the default"), joined with commas.
    static func list(_ values: [String?]) -> String {
        var v = values
        while let last = v.last, last == nil { v.removeLast() }
        return v.map { $0 ?? "*" }.joined(separator: ",")
    }

    /// The number a parameter stands for when it is a plain number or a formula without variables (nil otherwise,
    /// and for `""` / `*`).
    static func number(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty, raw != "*" else { return nil }
        return OptionValue.number(raw)
    }

    /// True when the text needs the skin to be evaluated: `#Var#` or `[Section]` references.
    static func usesVariables(_ raw: String) -> Bool {
        raw.contains("#") || raw.contains("[")
    }

    /// Remembers the normalised text of each parsed part, so unchanged parts are written back as they were.
    struct Sources<Value: Equatable> {
        var entries: [(value: Value, text: String)] = []

        /// For each value in order: the text of an unused source with an equal value, or nil.
        func texts(for values: [Value]) -> [String?] {
            var used = [Bool](repeating: false, count: entries.count)
            return values.map { v in
                guard let i = entries.indices.first(where: { !used[$0] && entries[$0].value == v }) else { return nil }
                used[i] = true
                return entries[i].text
            }
        }
    }
}

// MARK: - Arithmetic on parameter text

/// Builds parameter text for derived geometry: numbers when every operand is a number, otherwise a formula in
/// parentheses (`(#X# + 50)`), which the engine evaluates like any Number option.
enum ShapeExpr {
    static func format(_ v: Double) -> String { GeometryEdit.format(v) }

    static func operand(_ s: String) -> String { s.isEmpty ? "0" : s }

    static func add(_ a: String, _ b: String) -> String {
        if let x = ShapeText.number(operand(a)), let y = ShapeText.number(operand(b)) { return format(x + y) }
        return "(\(operand(a)) + \(operand(b)))"
    }

    static func subtract(_ a: String, _ b: String) -> String {
        if let x = ShapeText.number(operand(a)), let y = ShapeText.number(operand(b)) { return format(x - y) }
        return "(\(operand(a)) - \(operand(b)))"
    }

    static func multiply(_ a: String, _ k: Double) -> String {
        if let x = ShapeText.number(operand(a)) { return format(x * k) }
        return "(\(operand(a)) * \(format(k)))"
    }

    static func divide(_ a: String, _ k: Double) -> String {
        if let x = ShapeText.number(operand(a)) { return format(x / k) }
        return "(\(operand(a)) / \(format(k)))"
    }
}

// MARK: - ShapeSpec

/// One `Shape` / `ShapeN` option value: `Type parameters | Modifier parameters | …` — see the file comment for the
/// text rules.
public struct ShapeSpec {
    /// The shape types of the manual.
    public enum Kind: String, CaseIterable, Equatable {
        case rectangle, ellipse, line, arc, curve, path, path1, combine

        /// The keyword as the manual writes it.
        public var keyword: String {
            switch self {
            case .rectangle: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .line: return "Line"
            case .arc: return "Arc"
            case .curve: return "Curve"
            case .path: return "Path"
            case .path1: return "Path1"
            case .combine: return "Combine"
            }
        }

        /// Plain name for menus.
        public var title: String {
            switch self {
            case .path: return "Path"
            case .path1: return "Path (filled inside)"
            default: return keyword
            }
        }

        /// A kind in plain words, with its article: "a rectangle", "a circle", "a path".
        public static func plainName(_ kind: Kind) -> String {
            switch kind {
            case .rectangle: return "a rectangle"
            case .ellipse: return "a circle"
            case .line: return "a line"
            case .arc: return "an arc"
            case .curve: return "a curve"
            case .path, .path1: return "a path"
            case .combine: return "combined shapes"
            }
        }

        /// SF Symbol for the type pop-up.
        public var symbol: String {
            switch self {
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .line: return "line.diagonal"
            case .arc: return "circle.bottomhalf.filled"
            case .curve: return "scribble"
            case .path: return "hexagon"
            case .path1: return "hexagon.fill"
            case .combine: return "square.on.circle"
            }
        }

        /// Case-insensitive keyword lookup (`Shape1`-style digits are part of the keyword: only `Path1` has one).
        public init?(keyword: String) {
            guard let k = Kind(rawValue: keyword.lowercased()) else { return nil }
            self = k
        }
    }

    /// `Rotate` / `Scale` / `Skew` / `Offset` (the names `TransformOrder` lists).
    public enum TransformKind: String, CaseIterable, Equatable {
        case rotate, scale, skew, offset

        public var keyword: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// The value of a `Fill` / `Stroke` modifier. Colors and option names are kept as written.
    public enum Paint: Equatable {
        /// `Color R,G,B[,A]` (also written without the `Color` keyword, or as `FillColor` / `StrokeColor`).
        case color(String)
        /// `LinearGradient Name` / `LinearGradient1 Name` (`linearLight`: the `1` variant).
        case linearGradient(String, linearLight: Bool)
        /// `RadialGradient Name` / `RadialGradient1 Name`.
        case radialGradient(String, linearLight: Bool)

        /// `Color 255,0,0` / `LinearGradient1 Name`…
        public var text: String {
            switch self {
            case .color(let c): return ShapeText.join("Color", c)
            case .linearGradient(let n, let l): return ShapeText.join(l ? "LinearGradient1" : "LinearGradient", n)
            case .radialGradient(let n, let l): return ShapeText.join(l ? "RadialGradient1" : "RadialGradient", n)
            }
        }

        /// The color when this is a plain color that needs no variables (nil for gradients / `#Var#` colors).
        public var rgba: RGBA? {
            if case .color(let c) = self { return OptionValue.color(c) }
            return nil
        }

        /// The named gradient option, for gradients.
        public var gradientOption: String? {
            switch self {
            case .color: return nil
            case .linearGradient(let n, _), .radialGradient(let n, _): return n
            }
        }

        public var isRadial: Bool {
            if case .radialGradient = self { return true }
            return false
        }
    }

    /// Which modifier a `Modifier` sets; for the same slot the last modifier wins (manual).
    public enum Slot: Equatable, CaseIterable {
        case fill, stroke, strokeWidth, strokeDashes, strokeDashOffset, strokeDashCap, strokeStartCap, strokeEndCap
        case strokeLineJoin, strokeType, rotate, scale, skew, offset, transformOrder
    }

    /// One modifier after the shape (between `|`). Numbers are kept as written.
    public enum Modifier: Equatable {
        case fill(Paint)
        case stroke(Paint)
        case strokeWidth(String)
        /// Dash, gap, dash, gap… as multiples of StrokeWidth; empty = solid.
        case strokeDashes([String])
        case strokeDashOffset(String)
        case strokeDashCap(ShapeLineCap)
        case strokeStartCap(ShapeLineCap)
        case strokeEndCap(ShapeLineCap)
        /// `StrokeLineJoin Join[, MiterLimit]`.
        case strokeLineJoin(ShapeLineJoin, miterLimit: String?)
        /// `StrokeType Center|Outer|Inner` (Deskset extension).
        case strokeType(ShapeStrokePlacement)
        /// `Rotate Angle[, AnchorX, AnchorY]` (degrees, clockwise; anchors relative to the shape's top-left).
        case rotate(angle: String, anchorX: String?, anchorY: String?)
        /// `Scale X[, Y[, AnchorX, AnchorY]]`.
        case scale(x: String, y: String?, anchorX: String?, anchorY: String?)
        /// `Skew X[, Y[, AnchorX, AnchorY]]` (degrees).
        case skew(x: String, y: String?, anchorX: String?, anchorY: String?)
        /// `Offset X[, Y]`.
        case offset(x: String, y: String?)
        case transformOrder([TransformKind])
        /// `Extend Name, Name…`: inserts the modifiers of those options.
        case extend([String])
        /// A Combine step (`Union Shape2`…); only on a `Combine` shape.
        case combine(ShapeCombineMode, shape: String)
        /// `Consume 0|1` (Deskset extension, only on a `Combine` shape).
        case consume(String)
        /// Anything the model does not understand, kept exactly (whitespace-normalised).
        case unknown(String)

        /// Which slot the modifier sets (nil for Extend, Combine steps, Consume and unknown modifiers).
        public var slot: Slot? {
            switch self {
            case .fill: return .fill
            case .stroke: return .stroke
            case .strokeWidth: return .strokeWidth
            case .strokeDashes: return .strokeDashes
            case .strokeDashOffset: return .strokeDashOffset
            case .strokeDashCap: return .strokeDashCap
            case .strokeStartCap: return .strokeStartCap
            case .strokeEndCap: return .strokeEndCap
            case .strokeLineJoin: return .strokeLineJoin
            case .strokeType: return .strokeType
            case .rotate: return .rotate
            case .scale: return .scale
            case .skew: return .skew
            case .offset: return .offset
            case .transformOrder: return .transformOrder
            case .extend, .combine, .consume, .unknown: return nil
            }
        }

        /// Canonical text (`Fill Color 255,0,0`, `StrokeLineJoin Miter,4`, `Rotate 45,10,10`).
        public var text: String {
            switch self {
            case .fill(let p): return "Fill " + p.text
            case .stroke(let p): return "Stroke " + p.text
            case .strokeWidth(let w): return ShapeText.join("StrokeWidth", w)
            case .strokeDashes(let d): return ShapeText.join("StrokeDashes", d.joined(separator: ","))
            case .strokeDashOffset(let o): return ShapeText.join("StrokeDashOffset", o)
            case .strokeDashCap(let c): return "StrokeDashCap " + c.keyword
            case .strokeStartCap(let c): return "StrokeStartCap " + c.keyword
            case .strokeEndCap(let c): return "StrokeEndCap " + c.keyword
            case .strokeLineJoin(let j, let limit):
                return "StrokeLineJoin " + j.keyword + (limit.map { "," + $0 } ?? "")
            case .strokeType(let p): return "StrokeType " + p.keyword
            case .rotate(let a, let ax, let ay): return ShapeText.join("Rotate", ShapeText.list([a, ax, ay]))
            case .scale(let x, let y, let ax, let ay): return ShapeText.join("Scale", ShapeText.list([x, y, ax, ay]))
            case .skew(let x, let y, let ax, let ay): return ShapeText.join("Skew", ShapeText.list([x, y, ax, ay]))
            case .offset(let x, let y): return ShapeText.join("Offset", ShapeText.list([x, y]))
            case .transformOrder(let kinds): return ShapeText.join("TransformOrder", kinds.map(\.keyword).joined(separator: ","))
            case .extend(let names): return ShapeText.join("Extend", names.joined(separator: ","))
            case .combine(let mode, let shape): return ShapeText.join(mode.keyword, shape)
            case .consume(let v): return ShapeText.join("Consume", v)
            case .unknown(let raw): return raw
            }
        }

        /// Parses one (normalised) modifier part; `combine` enables Combine steps and Consume.
        static func parse(_ part: String, combine: Bool) -> Modifier {
            let (kw, args) = ShapeText.keyword(part)
            let items = ShapeText.items(args)
            func item(_ i: Int) -> String? { i < items.count ? items[i] : nil }
            switch kw.lowercased() {
            case "fill", "stroke":
                guard !args.isEmpty else { return .unknown(part) }
                let paint = Paint.parse(args)
                return kw.lowercased() == "fill" ? .fill(paint) : .stroke(paint)
            case "fillcolor":
                return args.isEmpty ? .unknown(part) : .fill(.color(args))
            case "strokecolor":
                return args.isEmpty ? .unknown(part) : .stroke(.color(args))
            case "strokewidth":
                return .strokeWidth(args)
            case "strokedashes":
                return .strokeDashes(items)
            case "strokedashoffset":
                return .strokeDashOffset(args)
            case "strokedashcap", "strokestartcap", "strokeendcap":
                guard let cap = ShapeLineCap(rawValue: args.lowercased()) else { return .unknown(part) }
                switch kw.lowercased() {
                case "strokedashcap": return .strokeDashCap(cap)
                case "strokestartcap": return .strokeStartCap(cap)
                default: return .strokeEndCap(cap)
                }
            case "strokelinejoin":
                guard (1...2).contains(items.count), let join = ShapeLineJoin.parse(items[0]) else { return .unknown(part) }
                return .strokeLineJoin(join, miterLimit: item(1))
            case "stroketype":
                guard let p = ShapeStrokePlacement.parse(args) else { return .unknown(part) }
                return .strokeType(p)
            case "rotate":
                guard items.count <= 3 else { return .unknown(part) }
                return .rotate(angle: item(0) ?? "", anchorX: item(1), anchorY: item(2))
            case "scale":
                guard items.count <= 4 else { return .unknown(part) }
                return .scale(x: item(0) ?? "", y: item(1), anchorX: item(2), anchorY: item(3))
            case "skew":
                guard items.count <= 4 else { return .unknown(part) }
                return .skew(x: item(0) ?? "", y: item(1), anchorX: item(2), anchorY: item(3))
            case "offset":
                guard items.count <= 2 else { return .unknown(part) }
                return .offset(x: item(0) ?? "", y: item(1))
            case "transformorder":
                // Names the engine does not know are ignored by it; they stay in the text until this modifier changes.
                return .transformOrder(ShapeText.parts(args, ",").compactMap { TransformKind(rawValue: $0.lowercased()) })
            case "extend":
                return .extend(args.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            case "consume" where combine:
                return .consume(args)
            default:
                if combine, let mode = ShapeCombineMode(rawValue: kw.lowercased()) { return .combine(mode, shape: args) }
                return .unknown(part)
            }
        }
    }

    /// A Combine step.
    public struct CombineStep: Equatable {
        public var operation: ShapeCombineMode
        /// `Shape`, `Shape2`… as written.
        public var shape: String

        public init(_ operation: ShapeCombineMode, _ shape: String) {
            self.operation = operation
            self.shape = shape
        }
    }

    public var kind: Kind
    /// Parameters as written, trimmed: comma-separated for the basic shapes (empty items and `*` kept), a single
    /// item (the option name / parent shape) for Path, Path1 and Combine.
    public var params: [String]
    /// Modifiers in written order; Combine steps are `.combine` modifiers.
    public var modifiers: [Modifier]
    /// The first word as written when it is not a shape type (`aaaa` in `aaaa 0,0,40,20`), from
    /// `parse(_:allowingUnknownType:)`. The engine draws nothing for it; the editor shows it and offers the real
    /// types (`withType`). `kind` is only a stand-in then (`.rectangle`), and `text` writes the word back. nil for
    /// every real type.
    public private(set) var unknownType: String?

    private var typeSource: (kind: Kind, params: [String], text: String)?
    private var modifierSources = ShapeText.Sources<Modifier>()

    public init(kind: Kind, params: [String] = [], modifiers: [Modifier] = []) {
        self.kind = kind
        self.params = params
        self.modifiers = modifiers
    }

    // MARK: Parsing and text

    /// Parses one Shape option value. nil only when the text is not a shape: empty, or its first word is not a
    /// shape type (the engine skips such a shape; see `problem(in:)` for the message).
    ///
    /// `allowingUnknownType`: a first word that is a word but not a shape type (a typo such as `Rectangel`) is kept
    /// in `unknownType`, and the parameters and modifiers are read as usual, so the editor can show everything and
    /// offer the valid types. Text whose first part is not a word stays nil.
    public static func parse(_ raw: String, allowingUnknownType: Bool = false) -> ShapeSpec? {
        let parts = ShapeText.parts(raw, "|").map(ShapeText.normalizedPart).filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        let (type, rest) = ShapeText.keyword(first)
        let kind: Kind
        var unknown: String?
        if let k = Kind(keyword: type) {
            kind = k
        } else if allowingUnknownType, type.first?.isLetter == true {
            kind = .rectangle
            unknown = type
        } else {
            return nil
        }
        let params: [String]
        switch kind {
        case .path, .path1, .combine: params = rest.isEmpty ? [] : [rest]
        default: params = ShapeText.items(rest)
        }
        var spec = ShapeSpec(kind: kind, params: params)
        spec.unknownType = unknown
        spec.typeSource = (kind, params, first)
        for part in parts.dropFirst() {
            let m = Modifier.parse(part, combine: kind == .combine)
            spec.modifiers.append(m)
            spec.modifierSources.entries.append((m, part))
        }
        return spec
    }

    /// The whitespace normalisation `text` preserves (see the file comment).
    public static func normalized(_ raw: String) -> String { ShapeText.normalized(raw) }

    /// The option value: unchanged parts as written (whitespace-normalised), changed parts canonical.
    public var text: String {
        var parts: [String] = []
        if let s = typeSource, s.kind == kind, s.params == params {
            parts.append(s.text)
        } else {
            parts.append(ShapeText.join(unknownType ?? kind.keyword, params.joined(separator: ",")))
        }
        let kept = modifierSources.texts(for: modifiers)
        for (m, source) in zip(modifiers, kept) { parts.append(source ?? m.text) }
        return parts.joined(separator: " | ")
    }

    // MARK: Parameters

    /// One parameter's definition, for the geometry fields of each type.
    public struct Parameter: Equatable {
        public var name: String
        public var label: String
        public var required: Bool
        /// What the engine uses when the parameter is missing, empty or `*` (in words or as a number).
        public var defaultValue: String
        public var role: Role

        public enum Role: Equatable {
            case x, y, length, angle
            /// 0 / 1 switch.
            case flag
            /// Another option of the meter (Path) or a shape (Combine).
            case name
        }

        init(_ name: String, _ label: String, _ role: Role, required: Bool = true, default d: String = "") {
            self.name = name
            self.label = label
            self.role = role
            self.required = required
            defaultValue = d
        }
    }

    /// The parameters of a type, in order (Curve lists the cubic form; its quadratic form ends after ControlY1,
    /// with ShapeEnding as the 7th value).
    public static func parameters(for kind: Kind) -> [Parameter] {
        switch kind {
        case .rectangle:
            return [Parameter("X", "X", .x), Parameter("Y", "Y", .y), Parameter("Width", "Width", .length),
                    Parameter("Height", "Height", .length),
                    Parameter("RadiusX", "Corner radius", .length, required: false, default: "0"),
                    Parameter("RadiusY", "Corner radius Y", .length, required: false, default: "same as X")]
        case .ellipse:
            return [Parameter("CenterX", "Center X", .x), Parameter("CenterY", "Center Y", .y),
                    Parameter("RadiusX", "Radius", .length),
                    Parameter("RadiusY", "Radius Y", .length, required: false, default: "same as X")]
        case .line:
            return [Parameter("StartX", "Start X", .x), Parameter("StartY", "Start Y", .y),
                    Parameter("EndX", "End X", .x), Parameter("EndY", "End Y", .y)]
        case .arc:
            return [Parameter("StartX", "Start X", .x), Parameter("StartY", "Start Y", .y),
                    Parameter("EndX", "End X", .x), Parameter("EndY", "End Y", .y),
                    Parameter("RadiusX", "Radius", .length, required: false, default: "half the distance"),
                    Parameter("RadiusY", "Radius Y", .length, required: false, default: "same as X"),
                    Parameter("RotationAngle", "Rotation", .angle, required: false, default: "0"),
                    Parameter("SweepDirection", "Counter-clockwise", .flag, required: false, default: "0"),
                    Parameter("ArcSize", "Large arc", .flag, required: false, default: "0"),
                    Parameter("ShapeEnding", "Closed", .flag, required: false, default: "0")]
        case .curve:
            return [Parameter("StartX", "Start X", .x), Parameter("StartY", "Start Y", .y),
                    Parameter("EndX", "End X", .x), Parameter("EndY", "End Y", .y),
                    Parameter("ControlX1", "Control X", .x), Parameter("ControlY1", "Control Y", .y),
                    Parameter("ControlX2", "Control 2 X", .x, required: false, default: "none (quadratic)"),
                    Parameter("ControlY2", "Control 2 Y", .y, required: false, default: "none (quadratic)"),
                    Parameter("ShapeEnding", "Closed", .flag, required: false, default: "0")]
        case .path, .path1:
            return [Parameter("PathOption", "Path option", .name)]
        case .combine:
            return [Parameter("Parent", "Parent shape", .name)]
        }
    }

    /// The i-th parameter as written; nil when it is missing, empty or `*` (the engine's default applies).
    public func param(_ i: Int) -> String? {
        guard i >= 0, i < params.count else { return nil }
        let p = params[i]
        return p.isEmpty || p == "*" ? nil : p
    }

    /// The i-th parameter's number when it is a plain number or a formula without variables.
    public func number(_ i: Int) -> Double? { ShapeText.number(param(i)) }

    /// The number of required parameters of the type (the engine skips the shape without them).
    private var requiredCount: Int { ShapeSpec.parameters(for: kind).filter(\.required).count }

    /// What an edit writes for the i-th parameter when it has no value, given how it was written before.
    ///
    /// Optional parameters get `*` (the engine's "default"), or keep an empty / `*` spelling the author used.
    /// Required parameters are never written as `*`: the engine skips the whole shape when a required item is `*`.
    /// An empty required item counts as 0, but only when another required item is a number (`Rectangle ,,,,5` is
    /// skipped), so an edit writes an explicit `0` there and only keeps an empty spelling the author already had.
    private func placeholder(at i: Int, previous: String?) -> String {
        if i < requiredCount { return previous == "" ? "" : "0" }
        if let previous, previous.isEmpty || previous == "*" { return previous }
        return "*"
    }

    /// Sets the i-th parameter (nil = the default): missing parameters before it are filled in (`placeholder`
    /// rules: `0` for required ones, `*` for optional ones), trailing defaults are dropped.
    public mutating func setParam(_ i: Int, _ value: String?) {
        guard i >= 0 else { return }
        var p = params
        if let value {
            while p.count <= i { p.append(placeholder(at: p.count, previous: nil)) }
            p[i] = value
        } else if i < p.count {
            p[i] = placeholder(at: i, previous: p[i])
        }
        let required = requiredCount
        while p.count > required, let last = p.last, last.isEmpty || last == "*" { p.removeLast() }
        params = p
    }

    /// Replaces several parameters at once (nil = default, `setParam` rules).
    mutating func setParams(_ values: [String?]) {
        let required = requiredCount
        var p: [String] = []
        for (i, v) in values.enumerated() {
            if let v {
                p.append(v)
            } else {
                // Keep the author's placeholder spelling for a default that was already a default.
                p.append(placeholder(at: i, previous: i < params.count ? params[i] : nil))
            }
        }
        while p.count > required, let last = p.last, last.isEmpty || last == "*" { p.removeLast() }
        params = p
    }

    // MARK: Typed geometry (parameters as written; nil = the engine default)

    public struct RectangleGeometry: Equatable {
        public var x: String, y: String, width: String, height: String
        /// Corner radius (default 0).
        public var radiusX: String?
        /// Vertical corner radius (default: radiusX).
        public var radiusY: String?

        public init(x: String, y: String, width: String, height: String, radiusX: String? = nil, radiusY: String? = nil) {
            self.x = x; self.y = y; self.width = width; self.height = height
            self.radiusX = radiusX; self.radiusY = radiusY
        }

        /// The corner radii the engine uses (defaults applied).
        public var effectiveRadiusX: String { radiusX ?? "0" }
        public var effectiveRadiusY: String { radiusY ?? effectiveRadiusX }
    }

    public struct EllipseGeometry: Equatable {
        public var centerX: String, centerY: String, radiusX: String
        /// Default: radiusX (a circle).
        public var radiusY: String?

        public init(centerX: String, centerY: String, radiusX: String, radiusY: String? = nil) {
            self.centerX = centerX; self.centerY = centerY; self.radiusX = radiusX; self.radiusY = radiusY
        }

        /// The vertical radius the engine uses (default: radiusX).
        public var effectiveRadiusY: String { radiusY ?? radiusX }
    }

    public struct LineGeometry: Equatable {
        public var startX: String, startY: String, endX: String, endY: String

        public init(startX: String, startY: String, endX: String, endY: String) {
            self.startX = startX; self.startY = startY; self.endX = endX; self.endY = endY
        }
    }

    public struct ArcGeometry: Equatable {
        public var startX: String, startY: String, endX: String, endY: String
        /// Default: half the distance from start to end.
        public var radiusX: String?
        /// Default: radiusX.
        public var radiusY: String?
        /// Degrees (default 0).
        public var rotation: String?
        /// `SweepDirection`: 0 clockwise (default), 1 counter-clockwise.
        public var sweepDirection: String?
        /// `ArcSize`: 0 small (default), 1 large.
        public var arcSize: String?
        /// `ShapeEnding`: 0 open (default), 1 closed.
        public var shapeEnding: String?

        public init(startX: String, startY: String, endX: String, endY: String, radiusX: String? = nil,
                    radiusY: String? = nil, rotation: String? = nil, sweepDirection: String? = nil,
                    arcSize: String? = nil, shapeEnding: String? = nil) {
            self.startX = startX; self.startY = startY; self.endX = endX; self.endY = endY
            self.radiusX = radiusX; self.radiusY = radiusY; self.rotation = rotation
            self.sweepDirection = sweepDirection; self.arcSize = arcSize; self.shapeEnding = shapeEnding
        }

        /// The radius the engine uses when none is given: half the distance from start to end (nil with variables).
        public var defaultRadius: Double? {
            guard let x1 = ShapeText.number(startX.isEmpty ? "0" : startX), let y1 = ShapeText.number(startY.isEmpty ? "0" : startY),
                  let x2 = ShapeText.number(endX.isEmpty ? "0" : endX), let y2 = ShapeText.number(endY.isEmpty ? "0" : endY)
            else { return nil }
            return ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)).squareRoot() / 2
        }
        /// Rotation in degrees with the default applied.
        public var effectiveRotation: String { rotation ?? "0" }

        public var isCounterClockwise: Bool {
            get { ShapeSpec.flag(sweepDirection) }
            set { sweepDirection = newValue ? "1" : nil }
        }
        public var isLarge: Bool {
            get { ShapeSpec.flag(arcSize) }
            set { arcSize = newValue ? "1" : nil }
        }
        public var isClosed: Bool {
            get { ShapeSpec.flag(shapeEnding) }
            set { shapeEnding = newValue ? "1" : nil }
        }
    }

    public struct CurveGeometry: Equatable {
        public var startX: String, startY: String, endX: String, endY: String
        public var controlX1: String, controlY1: String
        /// Both set: a cubic curve; otherwise quadratic.
        public var controlX2: String?, controlY2: String?
        /// `ShapeEnding`: 0 open (default), 1 closed.
        public var shapeEnding: String?

        public init(startX: String, startY: String, endX: String, endY: String, controlX1: String, controlY1: String,
                    controlX2: String? = nil, controlY2: String? = nil, shapeEnding: String? = nil) {
            self.startX = startX; self.startY = startY; self.endX = endX; self.endY = endY
            self.controlX1 = controlX1; self.controlY1 = controlY1
            self.controlX2 = controlX2; self.controlY2 = controlY2; self.shapeEnding = shapeEnding
        }

        public var isCubic: Bool { controlX2 != nil && controlY2 != nil }
        public var isClosed: Bool {
            get { ShapeSpec.flag(shapeEnding) }
            set { shapeEnding = newValue ? "1" : nil }
        }
    }

    static func flag(_ raw: String?) -> Bool { (ShapeText.number(raw) ?? 0) != 0 }

    private func required(_ i: Int) -> String { i < params.count ? params[i] : "" }

    /// Rectangle parameters (nil for other types). Setting it on another type changes nothing.
    public var rectangle: RectangleGeometry? {
        get {
            guard kind == .rectangle else { return nil }
            return RectangleGeometry(x: required(0), y: required(1), width: required(2), height: required(3),
                                     radiusX: param(4), radiusY: param(5))
        }
        set {
            guard kind == .rectangle, let g = newValue else { return }
            setParams([g.x, g.y, g.width, g.height, g.radiusX, g.radiusY])
        }
    }

    public var ellipse: EllipseGeometry? {
        get {
            guard kind == .ellipse else { return nil }
            return EllipseGeometry(centerX: required(0), centerY: required(1), radiusX: required(2), radiusY: param(3))
        }
        set {
            guard kind == .ellipse, let g = newValue else { return }
            setParams([g.centerX, g.centerY, g.radiusX, g.radiusY])
        }
    }

    public var line: LineGeometry? {
        get {
            guard kind == .line else { return nil }
            return LineGeometry(startX: required(0), startY: required(1), endX: required(2), endY: required(3))
        }
        set {
            guard kind == .line, let g = newValue else { return }
            setParams([g.startX, g.startY, g.endX, g.endY])
        }
    }

    public var arc: ArcGeometry? {
        get {
            guard kind == .arc else { return nil }
            return ArcGeometry(startX: required(0), startY: required(1), endX: required(2), endY: required(3),
                               radiusX: param(4), radiusY: param(5), rotation: param(6), sweepDirection: param(7),
                               arcSize: param(8), shapeEnding: param(9))
        }
        set {
            guard kind == .arc, let g = newValue else { return }
            setParams([g.startX, g.startY, g.endX, g.endY, g.radiusX, g.radiusY, g.rotation, g.sweepDirection,
                       g.arcSize, g.shapeEnding])
        }
    }

    /// Curve parameters. The engine reads a cubic curve when 8 or more values are given and the 7th and 8th are
    /// numbers; then ShapeEnding is the 9th value, otherwise the 7th.
    public var curve: CurveGeometry? {
        get {
            guard kind == .curve else { return nil }
            var trimmed = params
            while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
            let cubic = trimmed.count >= 8 && param(6) != nil && param(7) != nil
            return CurveGeometry(startX: required(0), startY: required(1), endX: required(2), endY: required(3),
                                 controlX1: required(4), controlY1: required(5),
                                 controlX2: cubic ? param(6) : nil, controlY2: cubic ? param(7) : nil,
                                 shapeEnding: cubic ? param(8) : param(6))
        }
        set {
            guard kind == .curve, let g = newValue else { return }
            // Setting either second control point makes the curve cubic (the other one starts at 0).
            if g.controlX2 != nil || g.controlY2 != nil {
                setParams([g.startX, g.startY, g.endX, g.endY, g.controlX1, g.controlY1, g.controlX2 ?? "0",
                           g.controlY2 ?? "0", g.shapeEnding])
            } else {
                setParams([g.startX, g.startY, g.endX, g.endY, g.controlX1, g.controlY1, g.shapeEnding])
            }
        }
    }

    /// The path definition option of a Path / Path1 shape.
    public var pathOption: String? {
        get { kind == .path || kind == .path1 ? param(0) : nil }
        set {
            guard kind == .path || kind == .path1 else { return }
            params = newValue.map { $0.isEmpty ? [] : [$0] } ?? []
        }
    }

    /// The parent shape of a Combine (`Shape`, `Shape2`…).
    public var combineParent: String? {
        get { kind == .combine ? param(0) : nil }
        set {
            guard kind == .combine else { return }
            params = newValue.map { $0.isEmpty ? [] : [$0] } ?? []
        }
    }

    /// The Combine steps in order. Setting replaces them where the first step was (or at the start).
    public var combineSteps: [CombineStep] {
        get {
            modifiers.compactMap { m in
                if case .combine(let mode, let shape) = m { return CombineStep(mode, shape) }
                return nil
            }
        }
        set {
            let at = modifiers.firstIndex { if case .combine = $0 { return true } else { return false } } ?? 0
            let before = modifiers[..<at].filter { if case .combine = $0 { return false } else { return true } }
            let after = modifiers[at...].filter { if case .combine = $0 { return false } else { return true } }
            modifiers = before + newValue.map { .combine($0.operation, shape: $0.shape) } + after
        }
    }

    /// Whether the outline is closed (closed shapes are filled white by default, open ones not filled). nil for
    /// Path / Path1, whose definition decides (`ClosePath`).
    public var isClosed: Bool? {
        switch kind {
        case .rectangle, .ellipse, .combine: return true
        case .line: return false
        case .arc: return arc?.isClosed
        case .curve: return curve?.isClosed
        case .path, .path1: return nil
        }
    }

    // MARK: Modifiers

    /// The modifier in effect for a slot: the last one of it (manual: "the last one wins").
    public func modifier(_ slot: Slot) -> Modifier? {
        modifiers.last { $0.slot == slot }
    }

    /// Sets a slot: replaces its last modifier in place and removes earlier ones of the same slot; appends when the
    /// slot had none. nil removes every modifier of the slot; a modifier of another slot changes nothing.
    public mutating func set(_ slot: Slot, _ modifier: Modifier?) {
        guard let modifier else {
            modifiers.removeAll { $0.slot == slot }
            return
        }
        guard modifier.slot == slot else { return }
        if let last = modifiers.lastIndex(where: { $0.slot == slot }) {
            modifiers[last] = modifier
            var i = last
            while i > 0 {
                i -= 1
                if modifiers[i].slot == slot { modifiers.remove(at: i) }
            }
        } else {
            modifiers.append(modifier)
        }
    }

    public var fill: Paint? {
        if case .fill(let p)? = modifier(.fill) { return p }
        return nil
    }

    public var stroke: Paint? {
        if case .stroke(let p)? = modifier(.stroke) { return p }
        return nil
    }

    /// The StrokeWidth as written (nil = default 1).
    public var strokeWidth: String? {
        if case .strokeWidth(let w)? = modifier(.strokeWidth) { return w }
        return nil
    }

    /// Sets (nil: removes) the Fill.
    public mutating func setFill(_ paint: Paint?) { set(.fill, paint.map { .fill($0) }) }

    /// "No fill": removes the Fill of an open shape (open shapes are not filled by default); writes a transparent
    /// fill otherwise, since closed shapes are filled white by default.
    public mutating func removeFill() {
        if isClosed == false { setFill(nil) } else { setFill(.color("0,0,0,0")) }
    }

    public mutating func setStroke(_ paint: Paint?) { set(.stroke, paint.map { .stroke($0) }) }
    public mutating func setStrokeWidth(_ width: String?) { set(.strokeWidth, width.map { .strokeWidth($0) }) }
    public mutating func setStrokeDashes(_ dashes: [String]?) { set(.strokeDashes, dashes.map { .strokeDashes($0) }) }
    public mutating func setStrokeDashOffset(_ offset: String?) { set(.strokeDashOffset, offset.map { .strokeDashOffset($0) }) }
    public mutating func setStrokeDashCap(_ cap: ShapeLineCap?) { set(.strokeDashCap, cap.map { .strokeDashCap($0) }) }
    public mutating func setStrokeStartCap(_ cap: ShapeLineCap?) { set(.strokeStartCap, cap.map { .strokeStartCap($0) }) }
    public mutating func setStrokeEndCap(_ cap: ShapeLineCap?) { set(.strokeEndCap, cap.map { .strokeEndCap($0) }) }
    public mutating func setStrokeLineJoin(_ join: ShapeLineJoin?, miterLimit: String? = nil) {
        set(.strokeLineJoin, join.map { .strokeLineJoin($0, miterLimit: miterLimit) })
    }
    public mutating func setStrokeType(_ placement: ShapeStrokePlacement?) { set(.strokeType, placement.map { .strokeType($0) }) }
    public mutating func setRotate(_ angle: String?, anchorX: String? = nil, anchorY: String? = nil) {
        set(.rotate, angle.map { .rotate(angle: $0, anchorX: anchorX, anchorY: anchorY) })
    }
    public mutating func setScale(_ x: String?, _ y: String? = nil, anchorX: String? = nil, anchorY: String? = nil) {
        set(.scale, x.map { .scale(x: $0, y: y, anchorX: anchorX, anchorY: anchorY) })
    }
    public mutating func setSkew(_ x: String?, _ y: String? = nil, anchorX: String? = nil, anchorY: String? = nil) {
        set(.skew, x.map { .skew(x: $0, y: y, anchorX: anchorX, anchorY: anchorY) })
    }
    public mutating func setOffset(_ x: String?, _ y: String? = nil) { set(.offset, x.map { .offset(x: $0, y: y) }) }
    public mutating func setTransformOrder(_ order: [TransformKind]?) { set(.transformOrder, order.map { .transformOrder($0) }) }

    // MARK: Changing the type

    /// The same shape as another type, carrying the geometry over: a rectangle's bounds become the ellipse inside
    /// them or the line along their diagonal (and back); Arc and Curve keep start and end (a new curve gets its
    /// control point in the middle). Formulas and variables are combined into formulas (`(#X# + 50)`). Modifiers
    /// are kept, except Combine steps and Consume when leaving Combine. Path / Path1 keep their option between each
    /// other; turning into Path or Combine leaves the option / parent empty (the editor asks for it); turning a Path or
    /// Combine into a basic shape starts from a 100 × 100 box.
    public func converted(to newKind: Kind) -> ShapeSpec {
        if unknownType != nil { return withType(newKind) }
        if newKind == kind { return self }
        var result = self
        result.kind = newKind
        if kind == .combine {
            result.modifiers = modifiers.filter { m in
                switch m {
                case .combine, .consume: return false
                default: return true
                }
            }
        }
        switch newKind {
        case .path, .path1:
            result.params = (kind == .path || kind == .path1) ? params : []
            return result
        case .combine:
            result.params = []
            return result
        default:
            break
        }
        // Start / end points of the source (a box's diagonal for boxes) and its bounding box.
        let (x1, y1, x2, y2) = endpoints()
        switch newKind {
        case .rectangle:
            let box = bounds()
            result.params = [box.x, box.y, box.w, box.h]
        case .ellipse:
            let box = bounds()
            let rx = ShapeExpr.divide(box.w, 2), ry = ShapeExpr.divide(box.h, 2)
            result.params = [ShapeExpr.add(box.x, rx), ShapeExpr.add(box.y, ry), rx] + (rx == ry ? [] : [ry])
        case .line, .arc:
            result.params = [x1, y1, x2, y2]
        case .curve:
            result.params = [x1, y1, x2, y2, ShapeExpr.divide(ShapeExpr.add(x1, x2), 2), ShapeExpr.divide(ShapeExpr.add(y1, y2), 2)]
        case .path, .path1, .combine:
            break
        }
        return result
    }

    /// A shape whose type word is unknown (`unknownType`) with `newKind` written in its place: only the word
    /// changes, the parameters and modifiers stay as written (a typo is fixed, nothing is converted). For a real type
    /// this is `converted(to:)`.
    public func withType(_ newKind: Kind) -> ShapeSpec {
        guard let unknownType else { return converted(to: newKind) }
        let current = text
        let rest = current.hasPrefix(unknownType) ? String(current.dropFirst(unknownType.count)) : ""
        if var reparsed = ShapeSpec.parse(newKind.keyword + rest) {
            reparsed.unknownType = nil
            return reparsed
        }
        var result = self
        result.unknownType = nil
        result.kind = newKind
        result.typeSource = nil
        return result
    }

    /// Two opposite corners (boxes) or start and end (open shapes), as parameter text.
    private func endpoints() -> (String, String, String, String) {
        func p(_ i: Int) -> String { param(i) ?? "0" }
        switch kind {
        case .rectangle:
            return (p(0), p(1), ShapeExpr.add(p(0), p(2)), ShapeExpr.add(p(1), p(3)))
        case .ellipse:
            let rx = p(2), ry = param(3) ?? p(2)
            return (ShapeExpr.subtract(p(0), rx), ShapeExpr.subtract(p(1), ry), ShapeExpr.add(p(0), rx), ShapeExpr.add(p(1), ry))
        case .line, .arc, .curve:
            return (p(0), p(1), p(2), p(3))
        case .path, .path1, .combine:
            return ("0", "0", "100", "100")
        }
    }

    /// The bounding box as parameter text: a rectangle's own X, Y, W, H; an ellipse's center minus its radii; the box
    /// between the start and end of the other shapes.
    private func bounds() -> (x: String, y: String, w: String, h: String) {
        func p(_ i: Int) -> String { param(i) ?? "0" }
        switch kind {
        case .rectangle:
            return (p(0), p(1), p(2), p(3))
        case .ellipse:
            let rx = p(2), ry = param(3) ?? p(2)
            return (ShapeExpr.subtract(p(0), rx), ShapeExpr.subtract(p(1), ry), ShapeExpr.multiply(rx, 2),
                    ShapeExpr.multiply(ry, 2))
        default:
            let (x1, y1, x2, y2) = endpoints()
            return ShapeSpec.box(x1, y1, x2, y2)
        }
    }

    /// The box between two corners: normalised (smallest corner first, positive size) when they are numbers.
    private static func box(_ x1: String, _ y1: String, _ x2: String, _ y2: String) -> (x: String, y: String, w: String, h: String) {
        func axis(_ a: String, _ b: String) -> (String, String) {
            if let u = ShapeText.number(a), let v = ShapeText.number(b) {
                return (ShapeExpr.format(min(u, v)), ShapeExpr.format(abs(v - u)))
            }
            return (a, ShapeExpr.subtract(b, a))
        }
        let (x, w) = axis(x1, x2), (y, h) = axis(y1, y2)
        return (x, y, w, h)
    }

    // MARK: Problems

    /// Why the engine would not draw this shape, in plain words (nil when it can, or when variables decide).
    public var problem: String? {
        if let unknownType { return "“\(unknownType)” is not a shape type — nothing is drawn" }
        let defs = ShapeSpec.parameters(for: kind)
        switch kind {
        case .path, .path1:
            return param(0) == nil ? "A path needs the name of its path option — nothing is drawn" : nil
        case .combine:
            return param(0) == nil ? "Combine needs a parent shape — nothing is drawn" : nil
        default:
            break
        }
        let needed = defs.filter(\.required)
        // A variable can stand for several parameters (`Rectangle #Box#`): only the skin can tell.
        if params.contains(where: ShapeText.usesVariables) && params.count < needed.count { return nil }
        var anyValue = false
        for (i, d) in needed.enumerated() {
            guard i < params.count else {
                let names = needed.map { $0.label.lowercased() }
                return "\(kind.keyword) needs \(ShapeSpec.listing(names)) — nothing is drawn"
            }
            let p = params[i]
            if p.isEmpty { continue }
            if ShapeText.usesVariables(p) || ShapeText.number(p) != nil {
                anyValue = true
            } else {
                return "“\(p)” is not a number (\(d.label.lowercased())) — nothing is drawn"
            }
        }
        return anyValue ? nil : "\(kind.keyword) needs numbers — nothing is drawn"
    }

    /// The message for an option value the visual editor cannot show at all (nil when it parses).
    public static func problem(in raw: String) -> String? {
        if let spec = parse(raw) { return spec.problem }
        let first = ShapeText.parts(raw, "|").first ?? ""
        let (type, _) = ShapeText.keyword(first)
        if type.isEmpty { return first.isEmpty ? "No shape — nothing is drawn" : "“\(first)” is not a shape — nothing is drawn" }
        return "“\(type)” is not a shape type — nothing is drawn"
    }

    static func listing(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    // MARK: Shape option names

    /// `Shape` → 1, `Shape2` → 2 (`Shape1` → 1), case-insensitive; nil for anything else.
    public static func index(ofOption name: String) -> Int? { ShapeParser.Resolver.shapeIndex(name) }

    /// The option key of shape N: `Shape` for 1, `ShapeN` otherwise.
    public static func optionKey(_ index: Int) -> String { index <= 1 ? "Shape" : "Shape\(index)" }
}

extension ShapeSpec: Equatable {
    /// Compares the parsed content; the remembered spellings do not count.
    public static func == (a: ShapeSpec, b: ShapeSpec) -> Bool {
        a.kind == b.kind && a.params == b.params && a.modifiers == b.modifiers && a.unknownType == b.unknownType
    }
}

extension ShapeSpec.Paint {
    /// The argument of a Fill / Stroke modifier; without a known paint keyword the whole text is a color (the
    /// engine's `Fill 255,0,0`).
    static func parse(_ args: String) -> ShapeSpec.Paint {
        let (kind, rest) = ShapeText.keyword(args)
        switch kind.lowercased() {
        case "color": return .color(rest)
        case "lineargradient": return .linearGradient(rest, linearLight: false)
        case "lineargradient1": return .linearGradient(rest, linearLight: true)
        case "radialgradient": return .radialGradient(rest, linearLight: false)
        case "radialgradient1": return .radialGradient(rest, linearLight: true)
        default: return .color(args)
        }
    }
}

// MARK: - Keywords of the engine's enums

extension ShapeLineCap {
    /// `Flat`, `Round`, `Square`, `Triangle`.
    public var keyword: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

extension ShapeLineJoin {
    /// `Miter`, `Bevel`, `Round`, `MiterOrBevel`.
    public var keyword: String {
        switch self {
        case .miter: return "Miter"
        case .bevel: return "Bevel"
        case .round: return "Round"
        case .miterOrBevel: return "MiterOrBevel"
        }
    }
}

extension ShapeStrokePlacement {
    /// `Center`, `Outer`, `Inner`.
    public var keyword: String {
        switch self {
        case .center: return "Center"
        case .outer: return "Outer"
        case .inner: return "Inner"
        }
    }

    /// The engine's spellings (also `Centre`, `Outside`, `Inside`), case-insensitive.
    static func parse(_ s: String) -> ShapeStrokePlacement? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "center", "centre": return .center
        case "outer", "outside": return .outer
        case "inner", "inside": return .inner
        default: return nil
        }
    }
}

extension ShapeCombineMode {
    /// `Union`, `Intersect`, `XOR`, `Exclude`.
    public var keyword: String {
        switch self {
        case .union: return "Union"
        case .intersect: return "Intersect"
        case .xor: return "XOR"
        case .exclude: return "Exclude"
        }
    }
}

// MARK: - Reordering shapes

/// One `Shape` / `ShapeN` option.
public struct ShapeOption: Equatable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// The result of reordering / removing shapes of a meter.
public struct ShapeRenumbering: Equatable {
    /// The new options in drawing order: `Shape`, `Shape2`… (Combine references rewritten).
    public var options: [ShapeOption]
    /// Old keys that no longer exist and must be removed from the meter.
    public var removedKeys: [String]
    /// What had to change beyond the numbering (Combine steps whose shape was removed…), in plain words.
    public var notes: [String]
}

extension ShapeSpec {
    /// Renumbers a meter's shapes after they were reordered or removed.
    ///
    /// `options` are the meter's shape options (any order; keys `Shape`, `ShapeN`); `newOrder` lists old keys in
    /// the new drawing order — keys left out are removed. The result numbers them `Shape`, `Shape2`… and rewrites
    /// every Combine reference (parent and steps) to the new names. A reference to a removed shape: the step is
    /// dropped; a removed parent is replaced by the first remaining step's shape (that step is dropped); a Combine
    /// left without any shape is removed as well. References to shapes that are not in `options` are kept as
    /// written. Values that are not shapes are moved unchanged.
    public static func renumber(_ options: [ShapeOption], newOrder: [String]) -> ShapeRenumbering {
        var byIndex: [Int: ShapeOption] = [:]
        for o in options { if let i = index(ofOption: o.key), byIndex[i] == nil { byIndex[i] = o } }
        var order: [Int] = []
        for key in newOrder {
            if let i = index(ofOption: key), byIndex[i] != nil, !order.contains(i) { order.append(i) }
        }
        var notes: [String] = []
        var dropped = Set(byIndex.keys).subtracting(order)
        let combines: [Int: ShapeSpec] = byIndex.compactMapValues { o in
            parse(o.value).flatMap { $0.kind == .combine ? $0 : nil }
        }
        /// A shape of the list that is being removed.
        func isDropped(_ name: String) -> Bool {
            guard let i = index(ofOption: name), byIndex[i] != nil else { return false }
            return dropped.contains(i)
        }
        /// A shape of the list that stays.
        func isKept(_ name: String) -> Bool {
            guard let i = index(ofOption: name), byIndex[i] != nil else { return false }
            return !dropped.contains(i)
        }
        // A Combine whose parent and steps are all removed goes too, which can empty further Combines: repeat.
        var changed = true
        while changed {
            changed = false
            for old in order where !dropped.contains(old) {
                guard let spec = combines[old], let parent = spec.combineParent, isDropped(parent),
                      !spec.combineSteps.contains(where: { isKept($0.shape) }) else { continue }
                notes.append("\(optionKey(old)): Combine removed — all of its shapes were removed")
                dropped.insert(old)
                changed = true
            }
        }
        let kept = order.filter { !dropped.contains($0) }
        var specs: [Int: ShapeSpec] = [:]
        for old in kept {
            guard var spec = combines[old] else { continue }
            var steps = spec.combineSteps
            steps.removeAll { step in
                guard isDropped(step.shape) else { return false }
                notes.append("\(optionKey(old)): step “\(step.operation.keyword) \(step.shape)” removed with its shape")
                return true
            }
            if let parent = spec.combineParent, isDropped(parent), let first = steps.firstIndex(where: { isKept($0.shape) }) {
                let promoted = steps.remove(at: first)
                notes.append("\(optionKey(old)): parent \(parent) was removed; \(promoted.shape) is the parent now")
                spec.combineParent = promoted.shape
            }
            spec.combineSteps = steps
            specs[old] = spec
        }
        var newIndex: [Int: Int] = [:]
        for (n, old) in kept.enumerated() { newIndex[old] = n + 1 }
        func rename(_ name: String) -> String {
            guard let i = index(ofOption: name), let n = newIndex[i], n != i else { return name }
            return optionKey(n)
        }
        var result: [ShapeOption] = []
        for (n, old) in kept.enumerated() {
            guard let original = byIndex[old] else { continue }
            var value = original.value
            if var spec = specs[old] {
                if let parent = spec.combineParent { spec.combineParent = rename(parent) }
                spec.combineSteps = spec.combineSteps.map { CombineStep($0.operation, rename($0.shape)) }
                value = spec.text
                if parse(original.value) == spec { value = original.value }
            }
            result.append(ShapeOption(optionKey(n + 1), value))
        }
        let newKeys = Set(result.map { $0.key.lowercased() })
        let removed = options.map(\.key).filter { key in
            guard index(ofOption: key) != nil else { return false }
            return !newKeys.contains(key.lowercased())
        }
        return ShapeRenumbering(options: result, removedKeys: removed, notes: notes)
    }
}

// MARK: - GradientSpec

/// A named gradient option used by `Fill|Stroke LinearGradient[1] Name` / `RadialGradient[1] Name`:
/// `Angle | Color ; Position | …` (linear) or `CenterX, CenterY[, OffsetX, OffsetY[, RadiusX[, RadiusY]]] | Color ;
/// Position | …` (radial). Everything is kept as written; `text` of an unchanged gradient is `normalized(input)`,
/// where stops are written `color ; position`.
public struct GradientSpec: Equatable {
    public struct Stop: Equatable {
        /// `R,G,B[,A]`, hex, or a variable, as written.
        public var color: String
        /// 0.0…1.0 as written; nil spreads the stops evenly.
        public var position: String?
        /// Fields after the position (the engine ignores them); kept so nothing is lost.
        public var extraFields: [String]

        public init(color: String, position: String? = nil, extraFields: [String] = []) {
            self.color = color
            self.position = position
            self.extraFields = extraFields
        }

        public var rgba: RGBA? { OptionValue.color(color) }
        public var positionValue: Double? { ShapeText.number(position) }
    }

    /// Linear: `[Angle]`; radial: `[CenterX, CenterY, OffsetX, OffsetY, RadiusX, RadiusY]` (trailing ones optional).
    public var head: [String]
    public var stops: [Stop]

    public init(head: [String], stops: [Stop]) {
        self.head = head
        self.stops = stops
    }

    /// A linear gradient (angle in degrees: 0 runs right → left, 90 bottom → top, 180 left → right, 270 top → bottom).
    public static func linear(angle: String, stops: [Stop]) -> GradientSpec {
        GradientSpec(head: [angle], stops: stops)
    }

    /// Parses a gradient option. nil when the value is empty.
    public static func parse(_ raw: String) -> GradientSpec? {
        let parts = ShapeText.parts(raw, "|").map(ShapeText.normalizedPart).filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        let stops: [Stop] = stopFields(parts).map { fields in
            Stop(color: fields[0], position: fields.count > 1 ? fields[1] : nil, extraFields: Array(fields.dropFirst(2)))
        }
        return GradientSpec(head: ShapeText.items(first), stops: stops)
    }

    /// The `;` fields of every stop part (after the head), normalised; parts without fields are dropped.
    private static func stopFields(_ parts: [String]) -> [[String]] {
        parts.dropFirst().map { ShapeText.parts($0, ";").map(ShapeText.normalizedPart) }.filter { !$0.isEmpty }
    }

    /// Parts joined with " | ", stop fields with " ; ", `normalizedPart` inside each field.
    public static func normalized(_ raw: String) -> String {
        let parts = ShapeText.parts(raw, "|").map(ShapeText.normalizedPart).filter { !$0.isEmpty }
        guard let first = parts.first else { return "" }
        return ([first] + stopFields(parts).map { $0.joined(separator: " ; ") }).joined(separator: " | ")
    }

    public var text: String {
        let stopTexts = stops.map { s in ([s.color] + (s.position.map { [$0] } ?? []) + s.extraFields).joined(separator: " ; ") }
        return ([head.joined(separator: ",")] + stopTexts).joined(separator: " | ")
    }

    /// Linear gradients: the angle as written (the first head value).
    public var angle: String? {
        get { head.first.flatMap { $0.isEmpty ? nil : $0 } }
        set { if head.isEmpty { head = [newValue ?? "0"] } else { head[0] = newValue ?? "0" } }
    }

    /// Radial gradients: head value i (0 CenterX, 1 CenterY, 2 OffsetX, 3 OffsetY, 4 RadiusX, 5 RadiusY) as written,
    /// nil when missing / `*`.
    public func radial(_ i: Int) -> String? {
        guard i >= 0, i < head.count, !head[i].isEmpty, head[i] != "*" else { return nil }
        return head[i]
    }

    /// Sets a radial head value (nil: default; see `ShapeSpec.setParam` for the rules).
    public mutating func setRadial(_ i: Int, _ value: String?) {
        guard i >= 0 else { return }
        if let value {
            while head.count <= i { head.append(head.count < 2 ? "0" : "*") }
            head[i] = value
        } else if i < head.count {
            head[i] = i < 2 ? "0" : "*"
        }
        while head.count > 2, let last = head.last, last.isEmpty || last == "*" { head.removeLast() }
    }
}

// MARK: - PathSpec

/// A path definition option used by `Path Name` / `Path1 Name`: `StartX, StartY | LineTo X, Y | ArcTo … | CurveTo …
/// | SetRoundJoin 0|1 | SetNoStroke 0|1 | ClosePath 0|1`. Same text rules as `ShapeSpec`.
public struct PathSpec {
    public enum Segment: Equatable {
        /// `LineTo X, Y`.
        case lineTo([String])
        /// `ArcTo X, Y[, RadiusX[, RadiusY[, RotationAngle[, SweepDirection[, ArcSize]]]]]`.
        case arcTo([String])
        /// `CurveTo X, Y, ControlX1, ControlY1[, ControlX2, ControlY2]`.
        case curveTo([String])
        /// `SetRoundJoin 0|1` (also `SetLineJoin`); nil = the bare command (counts as 1).
        case setRoundJoin(String?)
        case setNoStroke(String?)
        case closePath(String?)
        case unknown(String)

        public var text: String {
            switch self {
            case .lineTo(let p): return ShapeText.join("LineTo", p.joined(separator: ","))
            case .arcTo(let p): return ShapeText.join("ArcTo", p.joined(separator: ","))
            case .curveTo(let p): return ShapeText.join("CurveTo", p.joined(separator: ","))
            case .setRoundJoin(let v): return ShapeText.join("SetRoundJoin", v ?? "")
            case .setNoStroke(let v): return ShapeText.join("SetNoStroke", v ?? "")
            case .closePath(let v): return ShapeText.join("ClosePath", v ?? "")
            case .unknown(let raw): return raw
            }
        }

        static func parse(_ part: String) -> Segment {
            let (kw, args) = ShapeText.keyword(part)
            switch kw.lowercased() {
            case "lineto": return .lineTo(ShapeText.items(args))
            case "arcto": return .arcTo(ShapeText.items(args))
            case "curveto": return .curveTo(ShapeText.items(args))
            case "setroundjoin", "setlinejoin": return .setRoundJoin(args.isEmpty ? nil : args)
            case "setnostroke": return .setNoStroke(args.isEmpty ? nil : args)
            case "closepath": return .closePath(args.isEmpty ? nil : args)
            default: return .unknown(part)
            }
        }
    }

    /// `[StartX, StartY]` as written.
    public var start: [String]
    public var segments: [Segment]

    private var startSource: (start: [String], text: String)?
    private var segmentSources = ShapeText.Sources<Segment>()

    public init(start: [String], segments: [Segment] = []) {
        self.start = start
        self.segments = segments
    }

    /// Parses a path definition. nil when the value is empty.
    public static func parse(_ raw: String) -> PathSpec? {
        let parts = ShapeText.parts(raw, "|").map(ShapeText.normalizedPart).filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        var spec = PathSpec(start: ShapeText.items(first))
        spec.startSource = (spec.start, first)
        for part in parts.dropFirst() {
            let s = Segment.parse(part)
            spec.segments.append(s)
            spec.segmentSources.entries.append((s, part))
        }
        return spec
    }

    public static func normalized(_ raw: String) -> String { ShapeText.normalized(raw) }

    public var text: String {
        var parts: [String] = []
        if let s = startSource, s.start == start { parts.append(s.text) } else { parts.append(start.joined(separator: ",")) }
        for (seg, source) in zip(segments, segmentSources.texts(for: segments)) { parts.append(source ?? seg.text) }
        return parts.joined(separator: " | ")
    }

    /// Whether `ClosePath` closes the figure (the last ClosePath wins; a bare one counts as 1).
    public var isClosed: Bool {
        for s in segments.reversed() {
            if case .closePath(let v) = s { return v.map { (ShapeText.number($0) ?? 0) != 0 } ?? true }
        }
        return false
    }
}

extension PathSpec: Equatable {
    public static func == (a: PathSpec, b: PathSpec) -> Bool { a.start == b.start && a.segments == b.segments }
}
