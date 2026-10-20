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
    public private(set) var nodes: [SVGRenderNode] = []
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
            nodes = []
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
        nodes = SVGDocumentBuilder(root: root).build(width: finalW, height: finalH)
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

    public func lower() -> SVGDraw {
        skin.assertOwned()
        return SVGDraw(sourceID: drawingIdentity, revision: revision, contentFrame: contentFrame, nodes: nodes)
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
    private var elementCount = 0

    static func parse(xml: String) -> SVGNode? {
        guard xml.utf8.count <= 16 * 1024 * 1024, let data = xml.data(using: .utf8) else { return nil }
        let delegate = SVGDOMParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        guard delegate.root?.tag.lowercased() == "svg" else { return nil }
        return delegate.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        elementCount += 1
        guard stack.count < 64, elementCount <= 20_000 else { parser.abortParsing(); return }
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

    static func parseTransform(_ raw: String?) -> ShapeTransform {
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

// MARK: - Captured document resources and rendering tree

private struct SVGViewport {
    var width: Double
    var height: Double
    var diagonal: Double { hypot(width, height) / sqrt(2) }
}

private extension SVGNode {
    var presentation: [String: String] {
        var result: [String: String] = [:]
        for (key, value) in attributes { result[key.lowercased()] = value }
        if let inline = attribute("style") {
            for declaration in inline.split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1)
                if pair.count == 2 {
                    result[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                        pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return result
    }
}

private struct SVGInheritedStyle {
    var declarations: [String: String] = [:]
    func applying(_ node: SVGNode) -> Self {
        var next = self
        let inherited: Set<String> = ["fill", "stroke", "color", "fill-opacity", "stroke-opacity", "fill-rule",
                                      "clip-rule", "stroke-width", "stroke-linecap", "stroke-linejoin",
                                      "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "visibility",
                                      "stop-color", "stop-opacity"]
        for (key, value) in node.presentation where inherited.contains(key) && value != "inherit" {
            next.declarations[key] = value
        }
        return next
    }
    func value(_ key: String, _ fallback: String) -> String { declarations[key] ?? fallback }
}

/// Resolves the supported local SVG resources once, without retaining the mutable meter or DOM.
private final class SVGDocumentBuilder {
    private struct GradientKey: Hashable {
        var id: String
        var width: Double
        var height: Double
    }
    private let root: SVGNode
    private var references: [String: SVGNode] = [:]
    private var originalStyles: [String: SVGInheritedStyle] = [:]
    private var remainingNodes = 20_000
    private var remainingImageBytes = 16 * 1024 * 1024
    private var remainingResourceWork = 50_000
    private var gradients: [GradientKey: SVGGradient] = [:]
    private var invalidGradients: Set<GradientKey> = []
    private var imageData: [String: Data] = [:]

    init(root: SVGNode) {
        self.root = root
        index(root, inherited: SVGInheritedStyle())
    }

    private func index(_ node: SVGNode, inherited: SVGInheritedStyle) {
        let style = inherited.applying(node)
        if let id = node.attribute("id"), !id.isEmpty, references[id] == nil {
            references[id] = node
            originalStyles[id] = style
        }
        for child in node.children { index(child, inherited: style) }
    }

    func build(width: Double, height: Double) -> [SVGRenderNode] {
        guard width > 0, height > 0 else { return [] }
        return buildSVG(root, inherited: SVGInheritedStyle(), parent: SVGViewport(width: width, height: height),
                        size: SVGViewport(width: width, height: height), active: [], depth: 0, isRoot: true)
    }

    private static func length(_ raw: String?, relativeTo extent: Double, fallback: Double = 0) -> Double {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return fallback }
        if text.hasSuffix("%"), let number = Double(text.dropLast()), number.isFinite {
            return number / 100 * extent
        }
        return SVGDOMParser.parseLength(text) ?? fallback
    }

    private static func opacity(_ raw: String?) -> Double {
        length(raw, relativeTo: 1, fallback: 1).clamped(0, 1)
    }

    private static func localID(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.hasPrefix("#"), raw.count > 1 else { return nil }
        return String(raw.dropFirst())
    }

    private static func paintReference(_ raw: String?) -> (id: String, fallback: String)? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.hasPrefix("url("),
              let end = raw.firstIndex(of: ")") else { return nil }
        let inside = String(raw[raw.index(raw.startIndex, offsetBy: 4)..<end])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard let id = localID(inside) else { return nil }
        return (id, String(raw[raw.index(after: end)...]).trimmingCharacters(in: .whitespaces))
    }

    private func buildNode(_ node: SVGNode, inherited: SVGInheritedStyle, viewport: SVGViewport,
                           active: Set<String>, depth: Int) -> [SVGRenderNode] {
        guard depth < 64, remainingNodes > 0 else { return [] }
        remainingNodes -= 1
        let own = node.presentation
        guard own["display"]?.lowercased() != "none" else { return [] }
        let style = inherited.applying(node)
        let tag = node.tag.lowercased()
        if tag == "svg" {
            return buildSVG(node, inherited: inherited, parent: viewport, size: nil, active: active, depth: depth, isRoot: false)
        }
        var children: [SVGRenderNode] = []
        var transform = SVGShapeBuilder.parseTransform(node.attribute("transform"))
        switch tag {
        case "g":
            for child in node.children { children += buildNode(child, inherited: style, viewport: viewport, active: active, depth: depth + 1) }
        case "use":
            guard let id = Self.localID(node.attribute("xlink:href")), !active.contains(id), let target = references[id] else { return [] }
            transform = ShapeTransform.translation(Self.length(node.attribute("x"), relativeTo: viewport.width),
                                                     Self.length(node.attribute("y"), relativeTo: viewport.height)).then(transform)
            var next = active
            next.insert(id)
            if target.tag.lowercased() == "svg" {
                let size = SVGViewport(width: Self.length(node.attribute("width"), relativeTo: viewport.width,
                                                          fallback: Self.length(target.attribute("width"), relativeTo: viewport.width, fallback: viewport.width)),
                                       height: Self.length(node.attribute("height"), relativeTo: viewport.height,
                                                           fallback: Self.length(target.attribute("height"), relativeTo: viewport.height, fallback: viewport.height)))
                children = buildSVG(target, inherited: style, parent: viewport, size: size, active: next, depth: depth + 1, isRoot: false)
            } else {
                children = buildNode(target, inherited: style, viewport: viewport, active: next, depth: depth + 1)
            }
        case "image":
            if style.value("visibility", "visible") != "hidden", style.value("visibility", "visible") != "collapse",
               let image = image(node, viewport: viewport) { children = [.image(image)] }
        case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
            guard style.value("visibility", "visible") != "hidden", style.value("visibility", "visible") != "collapse",
                  let path = geometry(node, viewport: viewport, rule: style.value("fill-rule", "nonzero")) else { return [] }
            var stroke = ShapeStrokeStyle()
            stroke.width = max(0, Self.length(style.declarations["stroke-width"], relativeTo: viewport.diagonal, fallback: 1))
            switch style.value("stroke-linecap", "butt") {
            case "round": stroke.startCap = .round; stroke.endCap = .round; stroke.dashCap = .round
            case "square": stroke.startCap = .square; stroke.endCap = .square; stroke.dashCap = .square
            default: break
            }
            switch style.value("stroke-linejoin", "miter") {
            case "round": stroke.join = .round
            case "bevel": stroke.join = .bevel
            default: break
            }
            stroke.miterLimit = max(1, Self.length(style.declarations["stroke-miterlimit"], relativeTo: 1, fallback: 4))
            if stroke.width > 0, let dash = style.declarations["stroke-dasharray"], dash != "none" {
                var values = dash.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { Self.length(String($0), relativeTo: viewport.diagonal) }
                if values.allSatisfy({ $0 >= 0 }), values.contains(where: { $0 > 0 }) {
                    if values.count % 2 != 0 { values += values }
                    stroke.dashes = values.map { $0 / stroke.width }
                }
                stroke.dashOffset = Self.length(style.declarations["stroke-dashoffset"], relativeTo: viewport.diagonal) / stroke.width
            }
            children = [.path(SVGPathDraw(path: path,
                                         fill: paint(style.value("fill", "black"), style: style, viewport: viewport),
                                         stroke: paint(style.value("stroke", "none"), style: style, viewport: viewport),
                                         strokeStyle: stroke, fillOpacity: Self.opacity(style.declarations["fill-opacity"]),
                                         strokeOpacity: Self.opacity(style.declarations["stroke-opacity"])))]
        default: return []
        }
        guard !children.isEmpty else { return [] }
        return [.group(transform: transform, opacity: Self.opacity(own["opacity"]),
                       clip: clip(own["clip-path"], viewport: viewport, active: active, depth: depth + 1), children: children)]
    }

    private func buildSVG(_ node: SVGNode, inherited: SVGInheritedStyle, parent: SVGViewport, size: SVGViewport?,
                          active: Set<String>, depth: Int, isRoot: Bool) -> [SVGRenderNode] {
        guard depth < 64, remainingNodes > 0, node.presentation["display"] != "none" else { return [] }
        remainingNodes -= 1
        let size = size ?? SVGViewport(width: Self.length(node.attribute("width"), relativeTo: parent.width, fallback: parent.width),
                                      height: Self.length(node.attribute("height"), relativeTo: parent.height, fallback: parent.height))
        guard size.width > 0, size.height > 0 else { return [] }
        let viewBox = SVGDOMParser.parseViewBox(node.attribute("viewBox"))
        if let viewBox, viewBox.width <= 0 || viewBox.height <= 0 { return [] }
        let viewport = SVGViewport(width: viewBox?.width ?? size.width, height: viewBox?.height ?? size.height)
        let style = inherited.applying(node)
        var children: [SVGRenderNode] = []
        for child in node.children { children += buildNode(child, inherited: style, viewport: viewport, active: active, depth: depth + 1) }
        guard !children.isEmpty else { return [] }
        var mapping = ShapeTransform.identity
        if let vb = viewBox {
            let aspect = Self.aspect(node.attribute("preserveAspectRatio"))
            var sx = size.width / vb.width
            var sy = size.height / vb.height
            if !aspect.none { let scale = aspect.slice ? max(sx, sy) : min(sx, sy); sx = scale; sy = scale }
            mapping = ShapeTransform.translation(-vb.minX, -vb.minY)
                .then(ShapeTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0))
                .then(.translation((size.width - vb.width * sx) * aspect.x.rawValue,
                                   (size.height - vb.height * sy) * aspect.y.rawValue))
        }
        let inner = SVGRenderNode.group(transform: mapping, opacity: 1,
                                         clip: clip(node.presentation["clip-path"], viewport: viewport, active: active, depth: depth + 1), children: children)
        let position = isRoot ? ShapeTransform.identity : ShapeTransform.translation(
            Self.length(node.attribute("x"), relativeTo: parent.width), Self.length(node.attribute("y"), relativeTo: parent.height))
        let viewportClip = node.presentation["overflow"] == "visible" ? nil : Self.rectangleClip(size)
        return [.group(transform: position, opacity: Self.opacity(node.presentation["opacity"]), clip: viewportClip, children: [inner])]
    }

    private static func rectangleClip(_ size: SVGViewport) -> SVGClip {
        SVGClip(children: [.path(ShapePath(subpaths: [ShapeGeometryBuilder.rectangle(x: 0, y: 0, width: size.width, height: size.height)]))])
    }

    private func geometry(_ node: SVGNode, viewport: SVGViewport, rule: String) -> ShapePath? {
        var normalized = node
        normalized.attributes = [:]
        normalized.children = []
        for key in ["d", "points"] { if let value = node.attribute(key) { normalized.attributes[key] = value } }
        for key in ["x", "x1", "x2", "cx", "width", "rx"] {
            if let value = node.attribute(key) { normalized.attributes[key] = String(Self.length(value, relativeTo: viewport.width)) }
        }
        for key in ["y", "y1", "y2", "cy", "height", "ry"] {
            if let value = node.attribute(key) { normalized.attributes[key] = String(Self.length(value, relativeTo: viewport.height)) }
        }
        if let value = node.attribute("r") { normalized.attributes["r"] = String(Self.length(value, relativeTo: viewport.diagonal)) }
        var style = SVGStyle()
        style.fillRule = rule == "evenodd" ? .evenOdd : .nonZero
        var items: [ShapeItem] = []
        var index = 1
        SVGShapeBuilder.build(node: normalized, inheritedStyle: style, transform: .identity, index: &index, into: &items)
        guard case .path(let path)? = items.first?.geometry else { return nil }
        return path
    }

    private func paint(_ raw: String, style: SVGInheritedStyle, viewport: SVGViewport) -> SVGPaint {
        var colorValue = raw
        if let reference = Self.paintReference(raw) {
            if let gradient = gradient(reference.id, viewport: viewport) { return .gradient(gradient) }
            // SVG paint accepts one optional color/none fallback, not another paint server.
            colorValue = reference.fallback
        }
        let value = colorValue.lowercased() == "currentcolor" ? style.value("color", "black") : colorValue
        if case .color(let color) = SVGStyle.parsePaint(value) { return .color(color) }
        return .none
    }

    private func gradient(_ id: String, viewport: SVGViewport) -> SVGGradient? {
        let key = GradientKey(id: id, width: viewport.width, height: viewport.height)
        if let cached = gradients[key] { return cached }
        if invalidGradients.contains(key) { return nil }
        if let result = resolveGradient(id, viewport: viewport) {
            gradients[key] = result
            return result
        }
        invalidGradients.insert(key)
        return nil
    }

    private func resolveGradient(_ id: String, viewport: SVGViewport) -> SVGGradient? {
        guard let node = references[id], ["lineargradient", "radialgradient"].contains(node.tag.lowercased()) else { return nil }
        var chain: [SVGNode] = []
        var visited: Set<String> = []
        var current: String? = id
        while let key = current {
            guard remainingResourceWork > 0 else { return nil }
            remainingResourceWork -= 1
            guard visited.count < 64, !visited.contains(key), let next = references[key],
                  ["lineargradient", "radialgradient"].contains(next.tag.lowercased()) else { return nil }
            visited.insert(key)
            chain.append(next)
            current = Self.localID(next.attribute("xlink:href"))
        }
        var attributes: [String: String] = [:]
        for entry in chain.reversed() { for (key, value) in entry.presentation { attributes[key] = value } }
        let stopSource = chain.first(where: { $0.children.contains(where: { $0.tag.lowercased() == "stop" }) }) ?? node
        let inherited = stopSource.attribute("id").flatMap { originalStyles[$0] } ?? SVGInheritedStyle().applying(stopSource)
        var stops: [ShapeGradientStop] = []
        var previous = 0.0
        for stop in stopSource.children where stop.tag.lowercased() == "stop" {
            guard remainingResourceWork > 0 else { return nil }
            remainingResourceWork -= 1
            let values = inherited.applying(stop)
            let offset = max(previous, Self.length(stop.attribute("offset"), relativeTo: 1).clamped(0, 1))
            previous = offset
            let rawColor = values.value("stop-color", "black")
            let resolved = rawColor.lowercased() == "currentcolor" ? values.value("color", "black") : rawColor
            var color = RGBA.black
            if case .color(let parsed) = SVGStyle.parsePaint(resolved) { color = parsed }
            color.a *= Self.opacity(values.declarations["stop-opacity"])
            stops.append(ShapeGradientStop(color: color, position: offset))
        }
        let units: SVGCoordinateUnits = attributes["gradientunits"] == "userSpaceOnUse" ? .userSpaceOnUse : .objectBoundingBox
        let relative = units == .objectBoundingBox ? SVGViewport(width: 1, height: 1) : viewport
        func coordinate(_ name: String, _ fallback: String, _ extent: Double) -> Double {
            Self.length(attributes[name] ?? fallback, relativeTo: extent)
        }
        let kind: SVGGradient.Kind
        if node.tag.lowercased() == "lineargradient" {
            kind = .linear(start: ShapePoint(coordinate("x1", "0%", relative.width), coordinate("y1", "0%", relative.height)),
                           end: ShapePoint(coordinate("x2", "100%", relative.width), coordinate("y2", "0%", relative.height)))
        } else {
            let center = ShapePoint(coordinate("cx", "50%", relative.width), coordinate("cy", "50%", relative.height))
            let radius = coordinate("r", "50%", relative.diagonal)
            guard radius >= 0 else { return nil }
            var focus = ShapePoint(attributes["fx"].map { Self.length($0, relativeTo: relative.width) } ?? center.x,
                                   attributes["fy"].map { Self.length($0, relativeTo: relative.height) } ?? center.y)
            let distance = hypot(focus.x - center.x, focus.y - center.y)
            if distance > radius, distance > 0 {
                focus = ShapePoint(center.x + (focus.x - center.x) * radius / distance,
                                   center.y + (focus.y - center.y) * radius / distance)
            }
            kind = .radial(center: center, focus: focus, radius: radius)
        }
        let spread: SVGSpreadMethod = attributes["spreadmethod"] == "reflect" ? .reflect : attributes["spreadmethod"] == "repeat" ? .repeat : .pad
        return SVGGradient(kind: kind, units: units, transform: SVGShapeBuilder.parseTransform(attributes["gradienttransform"]), spread: spread, stops: stops)
    }

    private func clip(_ raw: String?, viewport: SVGViewport, active: Set<String>, depth: Int) -> SVGClip? {
        guard depth < 64, let reference = Self.paintReference(raw), !active.contains(reference.id),
              let node = references[reference.id], node.tag.lowercased() == "clippath" else { return nil }
        let units: SVGCoordinateUnits = node.attribute("clipPathUnits") == "objectBoundingBox" ? .objectBoundingBox : .userSpaceOnUse
        let localViewport = units == .objectBoundingBox ? SVGViewport(width: 1, height: 1) : viewport
        var next = active
        next.insert(reference.id)
        let style = originalStyles[reference.id] ?? SVGInheritedStyle().applying(node)
        var children: [SVGClipNode] = []
        for child in node.children {
            guard remainingNodes > 0 else { break }
            remainingNodes -= 1
            guard child.presentation["display"] != "none" else { continue }
            var target = child
            var targetStyle = style.applying(child)
            var transform = SVGShapeBuilder.parseTransform(child.attribute("transform"))
            if child.tag.lowercased() == "use" {
                guard let id = Self.localID(child.attribute("xlink:href")), !next.contains(id), let referenced = references[id],
                      ["path", "rect", "circle", "ellipse", "line", "polygon", "polyline"].contains(referenced.tag.lowercased()),
                      referenced.presentation["display"] != "none" else { continue }
                target = referenced
                targetStyle = targetStyle.applying(referenced)
                transform = SVGShapeBuilder.parseTransform(referenced.attribute("transform"))
                    .then(.translation(Self.length(child.attribute("x"), relativeTo: localViewport.width),
                                       Self.length(child.attribute("y"), relativeTo: localViewport.height))).then(transform)
            }
            guard targetStyle.value("visibility", "visible") != "hidden", targetStyle.value("visibility", "visible") != "collapse",
                  let path = geometry(target, viewport: localViewport, rule: targetStyle.value("clip-rule", "nonzero")) else { continue }
            let targetClip = clip(target.presentation["clip-path"], viewport: localViewport, active: next, depth: depth + 1)
            var childNode = SVGClipNode.group(transform: transform, clip: targetClip, children: [.path(path)])
            if child.tag.lowercased() == "use", let useClip = clip(child.presentation["clip-path"], viewport: localViewport, active: next, depth: depth + 1) {
                childNode = .group(transform: .identity, clip: useClip, children: [childNode])
            }
            children.append(childNode)
        }
        let ownClip = clip(node.presentation["clip-path"], viewport: localViewport, active: next, depth: depth + 1)
        if let ownClip { children = [.group(transform: .identity, clip: ownClip, children: children)] }
        return SVGClip(units: units, transform: SVGShapeBuilder.parseTransform(node.attribute("transform")), children: children)
    }

    private func image(_ node: SVGNode, viewport: SVGViewport) -> SVGImageDraw? {
        guard let raw = node.attribute("xlink:href"), let comma = raw.firstIndex(of: ",") else { return nil }
        let header = raw[..<comma].lowercased()
        guard ["data:image/png;base64", "data:image/jpeg;base64", "data:image/jpg;base64"].contains(header) else { return nil }
        let data: Data
        if let cached = imageData[raw] {
            data = cached
        } else {
            let encoded = raw[raw.index(after: comma)...]
            guard encoded.utf8.count <= 12 * 1024 * 1024,
                  let decoded = Data(base64Encoded: String(encoded.filter { !$0.isWhitespace })),
                  decoded.count <= 8 * 1024 * 1024, decoded.count <= remainingImageBytes else { return nil }
            let isPNG = decoded.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            let isJPEG = decoded.starts(with: [255, 216, 255])
            guard (header == "data:image/png;base64" && isPNG) || (header != "data:image/png;base64" && isJPEG) else { return nil }
            data = decoded
            remainingImageBytes -= data.count
            imageData[raw] = data
        }
        let width = Self.length(node.attribute("width"), relativeTo: viewport.width)
        let height = Self.length(node.attribute("height"), relativeTo: viewport.height)
        guard width > 0, height > 0 else { return nil }
        return SVGImageDraw(data: data, rect: SkinRect(x: Self.length(node.attribute("x"), relativeTo: viewport.width),
                                                      y: Self.length(node.attribute("y"), relativeTo: viewport.height), width: width, height: height),
                            preserveAspectRatio: Self.aspect(node.attribute("preserveAspectRatio")))
    }

    private static func aspect(_ raw: String?) -> SVGPreserveAspectRatio {
        let parts = (raw ?? "xMidYMid meet").split(whereSeparator: \.isWhitespace).map(String.init).filter { $0 != "defer" }
        guard let align = parts.first else { return SVGPreserveAspectRatio() }
        if align == "none" { return SVGPreserveAspectRatio(none: true) }
        let x: SVGPreserveAspectRatio.Alignment = align.hasPrefix("xMin") ? .min : align.hasPrefix("xMax") ? .max : .mid
        let y: SVGPreserveAspectRatio.Alignment = align.hasSuffix("YMin") ? .min : align.hasSuffix("YMax") ? .max : .mid
        return SVGPreserveAspectRatio(x: x, y: y, slice: parts.dropFirst().contains("slice"))
    }
}

private enum SVGPathParser {
    static func scanNumbers(_ s: String) -> [Double] {
        var out: [Double] = []
        let chars = Array(s.unicodeScalars)
        var i = 0
        while i < chars.count && out.count < ShapeParser.maxPathSegments * 2 + 2 {
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
            let iterationStart = i
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
            if i == iterationStart { break }
        }
        flushSubpath(closed: false)
        return subpaths
    }
}
