import Foundation

/// `Meter=SVG` — displays SVG images from a `.svg` file or inline SVG code, with dynamic `Attribute`, `Attribute2`…
/// overrides (`selector | attribute | value`).
///
/// Clean-room implementation from https://docs-v5.rainmeter.net/manual/meters/svg/.
public final class SVGMeter: Meter {
    public struct AttributeOverride: Equatable, Sendable {
        public var selector: String
        public var attribute: String
        public var value: String

        public init(selector: String, attribute: String, value: String) {
            self.selector = selector
            self.attribute = attribute
            self.value = value
        }
    }

    public private(set) var svgSource = ""
    public private(set) var attributeOverrides: [AttributeOverride] = []
    public private(set) var shapes: [ShapeItem] = []
    public private(set) var intrinsicSize: (width: Double, height: Double) = (0, 0)
    public private(set) var revision = 0
    let drawingIdentity = UUID()

    /// Root `<svg>` attributes after `AttributeN` overrides have been applied.
    public private(set) var rootAttributes: [String: String] = [:]
    /// Elements indexed by `id` attribute after `AttributeN` overrides have been applied.
    public private(set) var elementsByID: [String: [String: String]] = [:]

    private var cachedInput: (svgXML: String, overrides: [AttributeOverride], targetW: Double?, targetH: Double?)?

    public override func readMeterOptions() {
        let rawSVG = string("SVGImage").trimmingCharacters(in: .whitespacesAndNewlines)
        svgSource = rawSVG
        var overrides: [AttributeOverride] = []
        for entry in numberedOptions("Attribute") {
            let parts = entry.value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 2 else { continue }
            let selector = parts[0]
            let attr = parts[1]
            let val = parts.count >= 3 ? parts[2] : ""
            guard !selector.isEmpty, !attr.isEmpty else { continue }
            overrides.append(AttributeOverride(selector: selector, attribute: attr, value: val))
        }
        attributeOverrides = overrides
        rebuildSVGIfNeeded()
    }

    public override func updateMeter() {
        rebuildSVGIfNeeded()
    }

    public override func prepareProvisionalLayout() {
        rebuildSVGIfNeeded()
    }

    public func attributeValue(selector: String, attribute: String) -> String? {
        let sel = selector.trimmingCharacters(in: .whitespaces)
        let attrLower = attribute.trimmingCharacters(in: .whitespaces).lowercased()
        if sel.caseInsensitiveCompare("svg") == .orderedSame {
            return rootAttributes.first(where: { $0.key.lowercased() == attrLower })?.value
        }
        let cleanID = sel.hasPrefix("#") ? String(sel.dropFirst()) : sel
        if let attrs = elementsByID[cleanID] {
            return attrs.first(where: { $0.key.lowercased() == attrLower })?.value
        }
        return nil
    }

    private func loadSVGXML() -> String {
        guard !svgSource.isEmpty else { return "" }
        if svgSource.hasPrefix("<") || svgSource.lowercased().contains("<svg") {
            return svgSource
        }
        let path = skin.readablePath(skin.absolutePath(svgSource))
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ""
        }
        return TextDecoding.decode(data)
    }

    private func rebuildSVGIfNeeded() {
        let xml = loadSVGXML()
        let key = (svgXML: xml, overrides: attributeOverrides, targetW: widthOption, targetH: heightOption)
        if let cached = cachedInput,
           cached.svgXML == key.svgXML,
           cached.overrides == key.overrides,
           cached.targetW == key.targetW,
           cached.targetH == key.targetH {
            return
        }
        cachedInput = key
        guard !xml.isEmpty, var root = SVGDOMParser.parse(xml: xml) else {
            shapes = []
            intrinsicSize = (0, 0)
            rootAttributes = [:]
            elementsByID = [:]
            revision &+= 1
            return
        }
        for ov in attributeOverrides {
            root.apply(override: ov)
        }
        rootAttributes = root.attributes
        var byID: [String: [String: String]] = [:]
        root.collectIDs(into: &byID)
        elementsByID = byID

        let viewBox = SVGDOMParser.parseViewBox(root.attribute("viewBox"))
        let svgW = SVGDOMParser.parseLength(root.attribute("width"))
        let svgH = SVGDOMParser.parseLength(root.attribute("height"))
        let baseW = max(svgW ?? viewBox?.width ?? 100, 0)
        let baseH = max(svgH ?? viewBox?.height ?? 100, 0)
        intrinsicSize = (baseW, baseH)

        let natural = computeNaturalSize(baseW: baseW, baseH: baseH)
        let finalW = widthOption ?? natural.width
        let finalH = heightOption ?? natural.height

        let vbX = viewBox?.minX ?? 0
        let vbY = viewBox?.minY ?? 0
        let vbW = (viewBox?.width ?? baseW) > 0 ? (viewBox?.width ?? baseW) : 100
        let vbH = (viewBox?.height ?? baseH) > 0 ? (viewBox?.height ?? baseH) : 100
        let sx = finalW > 0 ? finalW / vbW : 1
        let sy = finalH > 0 ? finalH / vbH : 1
        let rootTransform = ShapeTransform.translation(-vbX, -vbY)
            .then(ShapeTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0))

        var built: [ShapeItem] = []
        var nextIndex = 1
        SVGShapeBuilder.build(node: root, inheritedStyle: SVGStyle(), transform: rootTransform,
                              index: &nextIndex, into: &built)
        shapes = built
        revision &+= 1
    }

    private func computeNaturalSize(baseW: Double, baseH: Double) -> (width: Double, height: Double) {
        guard baseW > 0, baseH > 0 else { return (0, 0) }
        if let w = widthOption, heightOption == nil {
            return (w.rounded(), (w * baseH / baseW).rounded())
        }
        if let h = heightOption, widthOption == nil {
            return ((h * baseW / baseH).rounded(), h.rounded())
        }
        return (baseW.rounded(), baseH.rounded())
    }

    public override func naturalSize() -> (width: Double, height: Double) {
        computeNaturalSize(baseW: intrinsicSize.width, baseH: intrinsicSize.height)
    }

    public func lower() -> ShapeDraw {
        skin.assertOwned()
        return ShapeDraw(sourceID: drawingIdentity, revision: revision, shapes: shapes, contentFrame: contentFrame)
    }
}

// MARK: - Lightweight SVG DOM & Path Parser

private struct SVGNode {
    var tag: String
    var attributes: [String: String]
    var children: [SVGNode]

    func attribute(_ name: String) -> String? {
        let lower = name.lowercased()
        return attributes.first(where: { $0.key.lowercased() == lower })?.value
    }

    mutating func setAttribute(_ name: String, value: String) {
        let lower = name.lowercased()
        if let existingKey = attributes.first(where: { $0.key.lowercased() == lower })?.key {
            attributes[existingKey] = value
        } else {
            attributes[name] = value
        }
    }

    mutating func apply(override ov: SVGMeter.AttributeOverride, isRoot: Bool = true) {
        let sel = ov.selector.trimmingCharacters(in: .whitespaces)
        let matches: Bool
        if sel == "*" {
            matches = true
        } else if sel.caseInsensitiveCompare("svg") == .orderedSame {
            matches = isRoot && tag.caseInsensitiveCompare("svg") == .orderedSame
        } else {
            let targetID = sel.hasPrefix("#") ? String(sel.dropFirst()) : sel
            matches = (attribute("id") == targetID)
        }
        if matches {
            setAttribute(ov.attribute, value: ov.value)
        }
        for i in children.indices {
            children[i].apply(override: ov, isRoot: false)
        }
    }

    func collectIDs(into map: inout [String: [String: String]]) {
        if let id = attribute("id"), !id.isEmpty {
            map[id] = attributes
        }
        for child in children {
            child.collectIDs(into: &map)
        }
    }
}

private final class SVGDOMParser: NSObject, XMLParserDelegate {
    private var stack: [SVGNode] = []
    private var root: SVGNode?

    static func parse(xml: String) -> SVGNode? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let delegate = SVGDOMParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return delegate.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        stack.append(SVGNode(tag: local, attributes: attributeDict, children: []))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let finished = stack.popLast() else { return }
        if stack.isEmpty {
            root = finished
        } else {
            stack[stack.count - 1].children.append(finished)
        }
    }

    static func parseLength(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        for unit in ["px", "pt", "dp", "dip"] where s.lowercased().hasSuffix(unit) {
            s = String(s.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !s.hasSuffix("%"), let v = Double(s), v.isFinite else { return nil }
        return v
    }

    static func parseViewBox(_ raw: String?) -> (minX: Double, minY: Double, width: Double, height: Double)? {
        guard let raw else { return nil }
        let nums = SVGPathParser.scanNumbers(raw)
        guard nums.count >= 4 else { return nil }
        return (nums[0], nums[1], nums[2], nums[3])
    }
}

private struct SVGStyle {
    var fill: ShapePaint = .color(.black)
    var stroke: ShapePaint = .none
    var strokeWidth: Double = 1
    var lineCap: ShapeLineCap = .flat
    var lineJoin: ShapeLineJoin = .miter
    var fillRule: ShapeFillRule = .nonZero
    var opacity: Double = 1
    var fillOpacity: Double = 1
    var strokeOpacity: Double = 1
    var displayNone: Bool = false

    func applying(from node: SVGNode) -> SVGStyle {
        var next = self
        var attrs = node.attributes
        if let styleStr = node.attribute("style") {
            for pair in styleStr.split(separator: ";") {
                let kv = pair.split(separator: ":", maxSplits: 1)
                if kv.count == 2 {
                    attrs[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        for (k, v) in attrs {
            switch k.lowercased() {
            case "fill":
                if let p = SVGStyle.parsePaint(v) { next.fill = p }
            case "stroke":
                if let p = SVGStyle.parsePaint(v) { next.stroke = p }
            case "stroke-width":
                if let w = SVGDOMParser.parseLength(v) { next.strokeWidth = max(w, 0) }
            case "stroke-linecap":
                switch v.lowercased() {
                case "round": next.lineCap = .round
                case "square": next.lineCap = .square
                default: next.lineCap = .flat
                }
            case "stroke-linejoin":
                switch v.lowercased() {
                case "round": next.lineJoin = .round
                case "bevel": next.lineJoin = .bevel
                default: next.lineJoin = .miter
                }
            case "fill-rule", "clip-rule":
                if v.lowercased() == "evenodd" { next.fillRule = .evenOdd }
                else if v.lowercased() == "nonzero" { next.fillRule = .nonZero }
            case "opacity":
                if let o = Double(v), o.isFinite { next.opacity *= o.clamped(0, 1) }
            case "fill-opacity":
                if let o = Double(v), o.isFinite { next.fillOpacity = o.clamped(0, 1) }
            case "stroke-opacity":
                if let o = Double(v), o.isFinite { next.strokeOpacity = o.clamped(0, 1) }
            case "display":
                if v.lowercased() == "none" { next.displayNone = true }
            case "visibility":
                if v.lowercased() == "hidden" { next.displayNone = true }
            default:
                break
            }
        }
        return next
    }

    static func parsePaint(_ raw: String) -> ShapePaint? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower == "none" || lower == "transparent" { return ShapePaint.none }
        let named: [String: RGBA] = [
            "black": RGBA(r: 0, g: 0, b: 0, a: 255),
            "white": RGBA(r: 255, g: 255, b: 255, a: 255),
            "red": RGBA(r: 255, g: 0, b: 0, a: 255),
            "green": RGBA(r: 0, g: 128, b: 0, a: 255),
            "lime": RGBA(r: 0, g: 255, b: 0, a: 255),
            "blue": RGBA(r: 0, g: 0, b: 255, a: 255),
            "yellow": RGBA(r: 255, g: 255, b: 0, a: 255),
            "cyan": RGBA(r: 0, g: 255, b: 255, a: 255),
            "aqua": RGBA(r: 0, g: 255, b: 255, a: 255),
            "magenta": RGBA(r: 255, g: 0, b: 255, a: 255),
            "fuchsia": RGBA(r: 255, g: 0, b: 255, a: 255),
            "gray": RGBA(r: 128, g: 128, b: 128, a: 255),
            "grey": RGBA(r: 128, g: 128, b: 128, a: 255),
            "silver": RGBA(r: 192, g: 192, b: 192, a: 255),
            "orange": RGBA(r: 255, g: 165, b: 0, a: 255),
            "purple": RGBA(r: 128, g: 0, b: 128, a: 255),
        ]
        if let c = named[lower] { return .color(c) }
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            if hex.count == 3 {
                let expanded = hex.map { "\($0)\($0)" }.joined()
                if let c = OptionValue.color(expanded) { return .color(c) }
            }
            if let c = OptionValue.color(hex) { return .color(c) }
        }
        if lower.hasPrefix("rgb(") || lower.hasPrefix("rgba("), s.hasSuffix(")") {
            let inside = String(s.dropFirst(lower.hasPrefix("rgba(") ? 5 : 4).dropLast())
            if let c = OptionValue.color(inside) { return .color(c) }
        }
        if let c = OptionValue.color(s) { return .color(c) }
        return nil
    }

    func effectiveFill() -> ShapePaint {
        let alphaFactor = (opacity * fillOpacity).clamped(0, 1)
        guard case .color(var c) = fill else { return fill }
        c.a = (c.a * alphaFactor).rounded().clamped(0, 255)
        return c.a > 0 ? .color(c) : .none
    }

    func effectiveStroke() -> ShapePaint {
        let alphaFactor = (opacity * strokeOpacity).clamped(0, 1)
        guard case .color(var c) = stroke else { return stroke }
        c.a = (c.a * alphaFactor).rounded().clamped(0, 255)
        return c.a > 0 && strokeWidth > 0 ? .color(c) : .none
    }
}

private enum SVGShapeBuilder {
    static func build(node: SVGNode, inheritedStyle: SVGStyle, transform: ShapeTransform,
                      index: inout Int, into items: inout [ShapeItem]) {
        let style = inheritedStyle.applying(from: node)
        guard !style.displayNone else { return }
        let localTransform = parseTransform(node.attribute("transform"))
        let combinedTransform = localTransform.then(transform)

        let tag = node.tag.lowercased()
        switch tag {
        case "svg", "g", "a":
            for child in node.children {
                build(node: child, inheritedStyle: style, transform: combinedTransform, index: &index, into: &items)
            }
        case "path":
            if let d = node.attribute("d"), !d.isEmpty {
                let subpaths = SVGPathParser.parse(d: d)
                if !subpaths.isEmpty {
                    appendShape(subpaths: subpaths, style: style, transform: combinedTransform, index: &index, into: &items)
                }
            }
        case "rect":
            let x = SVGDOMParser.parseLength(node.attribute("x")) ?? 0
            let y = SVGDOMParser.parseLength(node.attribute("y")) ?? 0
            let w = SVGDOMParser.parseLength(node.attribute("width")) ?? 0
            let h = SVGDOMParser.parseLength(node.attribute("height")) ?? 0
            let rx = SVGDOMParser.parseLength(node.attribute("rx")) ?? 0
            let ry = SVGDOMParser.parseLength(node.attribute("ry"))
            if w > 0, h > 0 {
                let sub = ShapeGeometryBuilder.rectangle(x: x, y: y, width: w, height: h, radiusX: rx, radiusY: ry)
                appendShape(subpaths: [sub], style: style, transform: combinedTransform, index: &index, into: &items)
            }
        case "circle":
            let cx = SVGDOMParser.parseLength(node.attribute("cx")) ?? 0
            let cy = SVGDOMParser.parseLength(node.attribute("cy")) ?? 0
            let r = SVGDOMParser.parseLength(node.attribute("r")) ?? 0
            if r > 0 {
                let sub = ShapeGeometryBuilder.ellipse(centerX: cx, centerY: cy, radiusX: r, radiusY: r)
                appendShape(subpaths: [sub], style: style, transform: combinedTransform, index: &index, into: &items)
            }
        case "ellipse":
            let cx = SVGDOMParser.parseLength(node.attribute("cx")) ?? 0
            let cy = SVGDOMParser.parseLength(node.attribute("cy")) ?? 0
            let rx = SVGDOMParser.parseLength(node.attribute("rx")) ?? 0
            let ry = SVGDOMParser.parseLength(node.attribute("ry")) ?? 0
            if rx > 0, ry > 0 {
                let sub = ShapeGeometryBuilder.ellipse(centerX: cx, centerY: cy, radiusX: rx, radiusY: ry)
                appendShape(subpaths: [sub], style: style, transform: combinedTransform, index: &index, into: &items)
            }
        case "line":
            let x1 = SVGDOMParser.parseLength(node.attribute("x1")) ?? 0
            let y1 = SVGDOMParser.parseLength(node.attribute("y1")) ?? 0
            let x2 = SVGDOMParser.parseLength(node.attribute("x2")) ?? 0
            let y2 = SVGDOMParser.parseLength(node.attribute("y2")) ?? 0
            var lineStyle = style
            lineStyle.fill = .none
            let sub = ShapeSubpath(start: ShapePoint(x1, y1), segments: [ShapeSegment(.line(to: ShapePoint(x2, y2)))], closed: false)
            appendShape(subpaths: [sub], style: lineStyle, transform: combinedTransform, index: &index, into: &items)
        case "polyline", "polygon":
            let nums = SVGPathParser.scanNumbers(node.attribute("points") ?? "")
            if nums.count >= 4 {
                let start = ShapePoint(nums[0], nums[1])
                var segs: [ShapeSegment] = []
                var i = 2
                while i + 1 < nums.count {
                    segs.append(ShapeSegment(.line(to: ShapePoint(nums[i], nums[i + 1]))))
                    i += 2
                }
                let closed = (tag == "polygon")
                var polyStyle = style
                if !closed, node.attribute("fill") == nil { polyStyle.fill = .none }
                let sub = ShapeSubpath(start: start, segments: segs, closed: closed)
                appendShape(subpaths: [sub], style: polyStyle, transform: combinedTransform, index: &index, into: &items)
            }
        default:
            break
        }
    }

    private static func appendShape(subpaths: [ShapeSubpath], style: SVGStyle, transform: ShapeTransform,
                                    index: inout Int, into items: inout [ShapeItem]) {
        let transformedSubpaths = subpaths.map { $0.transformed(transform) }
        let path = ShapePath(subpaths: transformedSubpaths, fillRule: style.fillRule)
        let closed = transformedSubpaths.contains(where: \.closed)
        let scaleFactor = sqrt(abs(transform.determinant))
        var strokeStyle = ShapeStrokeStyle()
        strokeStyle.width = style.strokeWidth * (scaleFactor.isFinite && scaleFactor > 0 ? scaleFactor : 1)
        strokeStyle.startCap = style.lineCap
        strokeStyle.endCap = style.lineCap
        strokeStyle.join = style.lineJoin
        let strokePaint = style.effectiveStroke()
        let strokePlan = strokePaint.isVisible ? ShapeStroker.plan(for: path, style: strokeStyle) : nil
        let bounds = ShapeMath.bounds(of: path) ?? ShapeRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        var visual = bounds
        if strokeStyle.width > 0 {
            if let strokePlan, let r = ShapeStroker.bounds(of: strokePlan) {
                visual = visual.union(r)
            } else {
                visual = visual.union(bounds.insetBy(-strokeStyle.width / 2))
            }
        }
        let item = ShapeItem(index: index, geometry: .path(path), closed: closed,
                             fill: style.effectiveFill(), stroke: strokePaint,
                             strokeStyle: strokeStyle, strokePlan: strokePlan,
                             paintTransform: transform, bounds: bounds, visualBounds: visual)
        index += 1
        items.append(item)
    }

    private static func parseTransform(_ raw: String?) -> ShapeTransform {
        guard let raw, !raw.isEmpty else { return .identity }
        var result = ShapeTransform.identity
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
            let nameStart = i
            while i < chars.count, chars[i].isLetter { i += 1 }
            let name = String(chars[nameStart..<i]).lowercased()
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard !name.isEmpty, i < chars.count, chars[i] == "(" else { break }
            i += 1
            let argStart = i
            while i < chars.count, chars[i] != ")" { i += 1 }
            let args = SVGPathParser.scanNumbers(String(chars[argStart..<i]))
            if i < chars.count { i += 1 }
            let step: ShapeTransform
            switch name {
            case "translate":
                let tx = args.first ?? 0
                let ty = args.count >= 2 ? args[1] : 0
                step = .translation(tx, ty)
            case "scale":
                let sx = args.first ?? 1
                let sy = args.count >= 2 ? args[1] : sx
                step = ShapeTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
            case "rotate":
                let deg = args.first ?? 0
                let cx = args.count >= 3 ? args[1] : 0
                let cy = args.count >= 3 ? args[2] : 0
                step = .rotation(degrees: deg, around: ShapePoint(cx, cy))
            case "skewx":
                step = .skew(degreesX: args.first ?? 0, degreesY: 0, around: .zero)
            case "skewy":
                step = .skew(degreesX: 0, degreesY: args.first ?? 0, around: .zero)
            case "matrix" where args.count >= 6:
                step = ShapeTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            default:
                step = .identity
            }
            // In SVG, transform="A B" applies B first, then A: p' = A(B(p)).
            result = step.then(result)
        }
        return result
    }
}

private enum SVGPathParser {
    static func scanNumbers(_ s: String) -> [Double] {
        var out: [Double] = []
        let chars = Array(s.unicodeScalars)
        var i = 0
        while i < chars.count {
            while i < chars.count, !(chars[i].value >= 48 && chars[i].value <= 57) && chars[i] != "-" && chars[i] != "+" && chars[i] != "." {
                i += 1
            }
            guard i < chars.count else { break }
            let start = i
            if chars[i] == "-" || chars[i] == "+" { i += 1 }
            var hasDot = false
            var hasDigit = false
            while i < chars.count {
                let c = chars[i]
                if c.value >= 48 && c.value <= 57 {
                    hasDigit = true
                    i += 1
                } else if c == "." && !hasDot {
                    hasDot = true
                    i += 1
                } else if (c == "e" || c == "E") && hasDigit {
                    i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
                } else {
                    break
                }
            }
            if hasDigit, let v = Double(String(String.UnicodeScalarView(chars[start..<i]))), v.isFinite {
                out.append(v)
            } else if i == start {
                i += 1
            }
        }
        return out
    }

    static func parse(d: String) -> [ShapeSubpath] {
        var subpaths: [ShapeSubpath] = []
        var currentSegments: [ShapeSegment] = []
        var subpathStart = ShapePoint.zero
        var current = ShapePoint.zero
        var hasSubpath = false
        var lastCubicControl: ShapePoint?
        var lastQuadControl: ShapePoint?

        func flushSubpath(closed: Bool) {
            if hasSubpath && (!currentSegments.isEmpty || closed) {
                subpaths.append(ShapeSubpath(start: subpathStart, segments: currentSegments, closed: closed))
            }
            currentSegments = []
            hasSubpath = closed
        }

        let chars = Array(d.unicodeScalars)
        var i = 0
        var currentCmd: Unicode.Scalar = "M"

        func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" || chars[i] == "\r" || chars[i] == "," {
                i += 1
            }
        }

        func nextNumber() -> Double? {
            skipSeparators()
            guard i < chars.count else { return nil }
            let start = i
            if chars[i] == "-" || chars[i] == "+" { i += 1 }
            var hasDot = false
            var hasDigit = false
            while i < chars.count {
                let c = chars[i]
                if c.value >= 48 && c.value <= 57 {
                    hasDigit = true
                    i += 1
                } else if c == "." && !hasDot {
                    hasDot = true
                    i += 1
                } else if (c == "e" || c == "E") && hasDigit {
                    i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
                } else {
                    break
                }
            }
            guard hasDigit, let v = Double(String(String.UnicodeScalarView(chars[start..<i]))), v.isFinite else {
                i = start
                return nil
            }
            return v
        }

        func nextFlag() -> Bool? {
            skipSeparators()
            guard i < chars.count else { return nil }
            if chars[i] == "0" { i += 1; return false }
            if chars[i] == "1" { i += 1; return true }
            return nil
        }

        while i < chars.count && subpaths.count + currentSegments.count < ShapeParser.maxPathSegments {
            skipSeparators()
            guard i < chars.count else { break }
            let c = chars[i]
            if (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) {
                currentCmd = c
                i += 1
            }
            let rel = currentCmd.value >= 97 && currentCmd.value <= 122
            switch currentCmd {
            case "Z", "z":
                flushSubpath(closed: true)
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil
            case "M", "m":
                guard let x = nextNumber(), let y = nextNumber() else { return subpaths }
                flushSubpath(closed: false)
                let pt = rel ? ShapePoint(current.x + x, current.y + y) : ShapePoint(x, y)
                subpathStart = pt
                current = pt
                hasSubpath = true
                currentCmd = rel ? "l" : "L"
                lastCubicControl = nil
                lastQuadControl = nil
            case "L", "l":
                guard let x = nextNumber(), let y = nextNumber() else { return subpaths }
                let pt = rel ? ShapePoint(current.x + x, current.y + y) : ShapePoint(x, y)
                if !hasSubpath { subpathStart = current; hasSubpath = true }
                currentSegments.append(ShapeSegment(.line(to: pt)))
                current = pt
                lastCubicControl = nil
                lastQuadControl = nil
            case "H", "h":
                guard let x = nextNumber() else { return subpaths }
                let pt = ShapePoint(rel ? current.x + x : x, current.y)
                if !hasSubpath { subpathStart = current; hasSubpath = true }
                currentSegments.append(ShapeSegment(.line(to: pt)))
                current = pt
                lastCubicControl = nil
                lastQuadControl = nil
            case "V", "v":
                guard let y = nextNumber() else { return subpaths }
                let pt = ShapePoint(current.x, rel ? current.y + y : y)
                if !hasSubpath { subpathStart = current; hasSubpath = true }
                currentSegments.append(ShapeSegment(.line(to: pt)))
                current = pt
                lastCubicControl = nil
                lastQuadControl = nil
            case "C", "c":
                guard let x1 = nextNumber(), let y1 = nextNumber(),
                      let x2 = nextNumber(), let y2 = nextNumber(),
                      let x = nextNumber(), let y = nextNumber() else { return subpaths }
                let c1 = rel ? ShapePoint(current.x + x1, current.y + y1) : ShapePoint(x1, y1)
                let c2 = rel ? ShapePoint(current.x + x2, current.y + y2) : ShapePoint(x2, y2)
                let pt = rel ? ShapePoint(current.x + x, current.y + y) : ShapePoint(x, y)
                if !hasSubpath { subpathStart = current; hasSubpath = true }
                currentSegments.append(ShapeSegment(.cubic(control1: c1, control2: c2, to: pt)))
                lastCubicControl = c2
                lastQuadControl = nil
                current = pt
            case "S", "s":
                guard let x2 = nextNumber(), let y2 = nextNumber(),
                      let x = nextNumber(), let y = nextNumber() else { return subpaths }
                let c1 = lastCubicControl.map { ShapePoint(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let c2 = rel ? ShapePoint(current.x + x2, current.y + y2) : ShapePoint(x2, y2)
                let pt = rel ? ShapePoint(current.x + x, current.y + y) : ShapePoint(x, y)
                if !hasSubpath { subpathStart = current; hasSubpath = true }
                currentSegments.append(ShapeSegment(.cubic(control1: c1, control2: c2, to: pt)))
                lastCubicControl = c2
                lastQuadControl = nil
                current = pt
            case "Q", "q":
                guard let x1 = nextNumber(), let y1 = nextNumber(),
                      let x = nextNumber(), let y = nextNumber() else { return subpaths }
                let c1 = rel ? ShapePoint(current.x + x1, current.y + y1) : ShapePoint(x1, y1)
                let pt = rel ? ShapePoint(current.x + x, current.y + y) : ShapePoint(x, y)
                if !hasSubpath { subpathStart = current; hasSubpath = true }
                currentSegments.append(ShapeSegment(.quadratic(control: c1, to: pt)))
                lastQuadControl = c1
                lastCubicControl = nil
                current = pt
            case "T", "t":
                guard let x = nextNumber(), let y = nextNumber() else { return subpaths }
                let c1 = lastQuadControl.map { ShapePoint(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let pt = rel ? ShapePoint(current.x + x, current.y + y) : ShapePoint(x, y)
                if !hasSubpath { subpathStart = current; hasSubpath = true }
                currentSegments.append(ShapeSegment(.quadratic(control: c1, to: pt)))
                lastQuadControl = c1
                lastCubicControl = nil
                current = pt
            case "A", "a":
                guard let rx = nextNumber(), let ry = nextNumber(),
                      let rot = nextNumber(),
                      let largeArc = nextFlag(),
                      let sweep = nextFlag(),
                      let x = nextNumber(), let y = nextNumber() else { return subpaths }
                let pt = rel ? ShapePoint(current.x + x, current.y + y) : ShapePoint(x, y)
                if !hasSubpath { subpathStart = current; hasSubpath = true }
                let arcSegs = ShapeGeometryBuilder.arc(from: current, to: pt, radiusX: rx, radiusY: ry,
                                                       rotation: rot, clockwise: sweep, largeArc: largeArc)
                for seg in arcSegs { currentSegments.append(ShapeSegment(seg)) }
                lastCubicControl = nil
                lastQuadControl = nil
                current = pt
            default:
                return subpaths
            }
        }
        flushSubpath(closed: false)
        return subpaths
    }
}
