import Foundation
@testable import DesksetCore

private func svgPaths(_ nodes: [SVGRenderNode]) -> [SVGPathDraw] {
    nodes.flatMap { node in
        switch node {
        case .group(_, _, _, let children): return svgPaths(children)
        case .path(let path): return [path]
        case .image: return []
        }
    }
}

private func svgImages(_ nodes: [SVGRenderNode]) -> [SVGImageDraw] {
    nodes.flatMap { node in
        switch node {
        case .group(_, _, _, let children): return svgImages(children)
        case .path: return []
        case .image(let image): return [image]
        }
    }
}

private func svgGroups(_ nodes: [SVGRenderNode]) -> [(ShapeTransform, Double, SVGClip?)] {
    nodes.flatMap { node in
        if case .group(let transform, let opacity, let clip, let children) = node {
            return [(transform, opacity, clip)] + svgGroups(children)
        }
        return []
    }
}

func runSVGMeterTests(_ t: TestRunner) {
    var retained: [Skin] = []
    defer { withExtendedLifetime(retained) {} }
    func meter(_ document: String, _ options: String = "") throws -> (Skin, SVGMeter) {
        let (skin, _) = try makeSkin(t, "[M]\nMeter=SVG\nSVGImage=" + document.replacingOccurrences(of: "\n", with: " ") + "\n" + options)
        retained.append(skin)
        skin.update()
        guard let meter = skin.meter(named: "M") as? SVGMeter else { throw FormulaError("missing SVG meter") }
        return (skin, meter)
    }
    func gradient(_ paint: SVGPaint?) -> SVGGradient? {
        if case .gradient(let value)? = paint { return value }
        return nil
    }

    t.suite("SVG: definitions do not draw and local uses inherit presentation") {
        let (_, m) = try meter("""
        <svg width="120" height="60"><defs><g id="item"><rect width="20" height="10"/><circle cx="30" cy="5" r="5" fill="blue"/></g></defs>
        <use xlink:href="#item" x="10" y="20" fill="red" transform="scale(2)" xmlns:xlink="http://www.w3.org/1999/xlink"/>
        <use href="#item"/><use xlink:href="https://example.invalid/other.svg#item"/></svg>
        """)
        let paths = svgPaths(m.nodes)
        t.equal(paths.count, 2)
        t.equal(paths.first?.fill, .color(RGBA(r: 255, g: 0, b: 0)))
        t.equal(paths.last?.fill, .color(RGBA(r: 0, g: 0, b: 255)))
        t.check(svgGroups(m.nodes).contains { $0.0 == ShapeTransform(a: 2, b: 0, c: 0, d: 2, tx: 20, ty: 40) })
        t.equal(m.shapes.count, 0, "the old diagnostic list does not make definitions visible")
    }

    t.suite("SVG: use width and height resize referenced svg viewports only") {
        let (_, m) = try meter("""
        <svg width="200" height="100"><defs><svg id="viewport" width="20" height="20" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>
        <rect id="plain" width="10" height="10"/></defs><use xlink:href="#viewport" width="80" height="40"/><use xlink:href="#plain" width="80" height="40"/></svg>
        """)
        let paths = svgPaths(m.nodes)
        t.equal(paths.count, 2)
        t.check(svgGroups(m.nodes).contains { $0.0 == ShapeTransform(a: 4, b: 0, c: 0, d: 4, tx: 20, ty: 0) })
        t.close(ShapeMath.bounds(of: paths[1].path)?.maxX ?? -1, 10)
    }

    t.suite("SVG: linear gradient defaults, monotonic stops, opacity and style precedence") {
        let (_, m) = try meter("""
        <svg width="200" height="80"><defs><linearGradient id="g"><stop offset="-10%" stop-color="red"/>
        <stop offset="80%" stop-color="green" style="stop-color:blue;stop-opacity:0.5"/><stop offset="20%"/>
        <stop offset="140%" stop-color="white"/></linearGradient></defs><rect width="200" height="80" fill="url(#g)"/></svg>
        """)
        let g = gradient(svgPaths(m.nodes).first?.fill)
        t.equal(g?.units, .objectBoundingBox)
        t.equal(g?.kind, .linear(start: .zero, end: ShapePoint(1, 0)))
        t.equal(g?.spread, .pad)
        t.equal(g?.stops.map(\.position), [0, 0.8, 0.8, 1])
        t.equal(g?.stops[1].color, RGBA(r: 0, g: 0, b: 255, a: 127.5))
        t.equal(g?.stops[2].color, .black)
    }

    t.suite("SVG: gradients inherit resources but own coordinates and stops win") {
        let (_, m) = try meter("""
        <svg width="200" height="100"><defs><linearGradient id="base" gradientUnits="userSpaceOnUse" x2="25%" spreadMethod="reflect" gradientTransform="translate(3,4)">
        <stop stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient>
        <linearGradient id="child" xlink:href="#base" y2="100%"/><linearGradient id="own" xlink:href="#base" spreadMethod="repeat"><stop stop-color="white"/></linearGradient></defs>
        <rect width="100" height="100" fill="url(#child)"/><rect width="20" height="20" stroke="url(#own)"/></svg>
        """)
        let paths = svgPaths(m.nodes)
        let g = gradient(paths[0].fill)
        t.equal(g?.units, .userSpaceOnUse)
        t.equal(g?.kind, .linear(start: .zero, end: ShapePoint(50, 100)))
        t.equal(g?.transform, .translation(3, 4))
        t.equal(g?.spread, .reflect)
        t.equal(g?.stops.count, 2)
        let own = gradient(paths[1].stroke)
        t.equal(own?.spread, .repeat)
        t.equal(own?.stops.count, 1)
        t.equal(own?.stops.first?.color, .white)
    }

    t.suite("SVG: radial defaults, final center inheritance and viewport radius") {
        let (_, m) = try meter("""
        <svg width="200" height="100"><defs><radialGradient id="base"><stop/><stop offset="1" stop-color="white"/></radialGradient>
        <radialGradient id="user" xlink:href="#base" cx="25%" cy="100%" gradientUnits="userSpaceOnUse"/>
        <radialGradient id="focus" xlink:href="#base" fx="200%" fy="50%"/></defs>
        <rect width="20" height="20" fill="url(#base)"/><rect width="20" height="20" fill="url(#user)"/>
        <rect width="20" height="20" fill="url(#focus)"/></svg>
        """)
        let paths = svgPaths(m.nodes)
        t.equal(gradient(paths[0].fill)?.kind, .radial(center: ShapePoint(0.5, 0.5), focus: ShapePoint(0.5, 0.5), radius: 0.5))
        if case .radial(let center, let focus, let radius)? = gradient(paths[1].fill)?.kind {
            t.equal(center, ShapePoint(50, 100)); t.equal(focus, center)
            t.close(radius, hypot(200, 100) / sqrt(2) / 2)
        } else { t.check(false, "missing radial gradient") }
        if case .radial(_, let focus, _)? = gradient(paths[2].fill)?.kind { t.equal(focus, ShapePoint(1, 0.5)) }
        else { t.check(false, "missing constrained focus") }
    }

    t.suite("SVG: missing and cyclic resources are bounded and paint fallbacks survive") {
        let (_, m) = try meter("""
        <svg><defs><use id="loop" xlink:href="#loop"/><linearGradient id="a" xlink:href="#b"/><linearGradient id="b" xlink:href="#a"/></defs>
        <use xlink:href="#loop"/><use xlink:href="#missing"/><rect width="10" height="10" fill="url(#a) red"/>
        <rect width="10" height="10" fill="url(#missing)"/><rect width="10" height="10" clip-path="url(#missing)"/></svg>
        """)
        let paths = svgPaths(m.nodes)
        t.equal(paths.count, 3)
        t.equal(paths[0].fill, .color(RGBA(r: 255, g: 0, b: 0)))
        t.equal(paths[1].fill, .none)
        t.check(svgGroups(m.nodes).allSatisfy { $0.2 == nil || $0.2?.children.count == 1 }, "invalid clip references add no clip")
    }

    t.suite("SVG: group opacity composites once while fill opacity inherits") {
        let (_, m) = try meter("""
        <svg><g opacity="0.5" fill-opacity="0.4"><rect width="20" height="20"/><rect x="10" width="20" height="20" opacity="0.6"/></g></svg>
        """)
        let paths = svgPaths(m.nodes)
        t.equal(paths.map(\.fillOpacity), [0.4, 0.4])
        t.equal(paths.map(\.fill), [.color(.black), .color(.black)])
        t.equal(svgGroups(m.nodes).filter { $0.1 != 1 }.map { $0.1 }, [0.5, 0.6])
    }

    t.suite("SVG: paint fallbacks accept one color and do not recurse through invalid servers") {
        let invalidChain = String(repeating: "url(#missing) ", count: 2_048) + "red"
        let (_, m) = try meter("<svg><rect width=\"10\" height=\"10\" fill=\"url(#missing) blue\"/><rect width=\"10\" height=\"10\" fill=\"\(invalidChain)\"/></svg>")
        let paths = svgPaths(m.nodes)
        t.equal(paths.count, 2)
        t.equal(paths.first?.fill, .color(RGBA(r: 0, g: 0, b: 255)))
        t.equal(paths.last?.fill, SVGPaint.none, "a chain of invalid url fallbacks cannot recurse")
    }

    t.suite("SVG: clips capture child unions, nesting, transforms and clip rules") {
        let (_, m) = try meter("""
        <svg width="100" height="100"><defs><rect id="box" width="20" height="20"/><g id="not-shape"><rect width="20" height="20"/></g>
        <clipPath id="other"><circle cx="10" cy="10" r="10"/></clipPath>
        <clipPath id="c" transform="translate(3,4)" clipPathUnits="objectBoundingBox"><rect width="50%" height="100%" clip-rule="evenodd"/>
        <use xlink:href="#box" x="0.5"/><use xlink:href="#not-shape"/></clipPath></defs>
        <g clip-path="url(#other)"><rect width="100" height="100" clip-path="url(#c)"/></g><rect width="10" height="10" clip-path="url(#empty)"/>
        <defs><clipPath id="empty"/></defs></svg>
        """)
        let clips = svgGroups(m.nodes).compactMap { $0.2 }
        let object = clips.first { $0.units == .objectBoundingBox }
        t.equal(object?.transform, .translation(3, 4))
        t.equal(object?.children.count, 2, "clip use supports direct basic-shape targets only")
        if case .group(_, _, let children)? = object?.children.first, case .path(let path)? = children.first {
            t.equal(path.fillRule, .evenOdd)
            t.close(ShapeMath.bounds(of: path)?.maxX ?? -1, 0.5)
        } else { t.check(false, "missing clip geometry") }
        t.check(clips.contains { $0.children.isEmpty }, "an existing empty clip masks all content")
        t.check(clips.count >= 4, "viewport, parent, child and empty clips remain separate intersections")
    }

    t.suite("SVG: embedded images capture bytes and reject external or unsupported formats") {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="
        let (_, m) = try meter("""
        <svg width="200" height="100"><image x="10%" y="20%" width="50%" height="60%" preserveAspectRatio="xMaxYMin slice" xlink:href="data:image/png;base64,\(png)"/>
        <image width="10" height="10" xlink:href="https://example.invalid/image.png"/><image width="10" height="10" xlink:href="file:///tmp/image.png"/>
        <image width="10" height="10" xlink:href="data:image/svg+xml;base64,PHN2Zy8+"/><image width="10" height="10" href="data:image/png;base64,\(png)"/>
        <image width="10" height="10" xlink:href="data:image/png;base64,not-base64"/></svg>
        """)
        let images = svgImages(m.nodes)
        t.equal(images.count, 1)
        t.equal(images.first?.data, Data(base64Encoded: png))
        t.equal(images.first?.rect, SkinRect(x: 20, y: 20, width: 100, height: 60))
        t.equal(images.first?.preserveAspectRatio, SVGPreserveAspectRatio(x: .max, y: .min, slice: true))
    }

    t.suite("SVG: clip uses exclude referenced shapes with display none") {
        let (_, m) = try meter("""
        <svg><defs><rect id="hidden" width="90" height="90" display="none"/><rect id="shown" width="10" height="10"/>
        <clipPath id="c"><use xlink:href="#hidden"/><use xlink:href="#shown"/></clipPath></defs>
        <rect width="100" height="100" clip-path="url(#c)"/></svg>
        """)
        let clipping = svgGroups(m.nodes).compactMap { $0.2 }.last
        t.equal(clipping?.children.count, 1)
        if case .group(_, _, let children)? = clipping?.children.first, case .path(let path)? = children.first {
            t.close(ShapeMath.bounds(of: path)?.maxX ?? -1, 10)
        } else { t.check(false, "missing visible clip use") }
    }

    t.suite("SVG: overrides rebuild resources and immutable snapshots retain their document") {
        let (skin, m) = try meter("<svg width=\"100\" height=\"50\"><defs><linearGradient id=\"g\"><stop id=\"stop\" stop-color=\"red\"/><stop offset=\"1\"/></linearGradient></defs><rect id=\"box\" width=\"100\" height=\"50\" fill=\"url(#g)\"/></svg>", "Attribute=#stop | stop-color | blue")
        let first = m.lower()
        let firstRevision = m.revision
        t.equal(gradient(svgPaths(first.nodes).first?.fill)?.stops.first?.color, RGBA(r: 0, g: 0, b: 255))
        skin.update()
        t.equal(m.revision, firstRevision)
        skin.perform(Bang(name: "setoption", args: ["M", "X", "40"]))
        skin.update()
        t.equal(m.revision, firstRevision, "moving a meter does not rebuild its document")
        t.equal(m.lower().sourceID, first.sourceID)
        t.equal(m.lower().nodes, first.nodes)
        t.close(m.lower().contentFrame.x, 40)
        skin.perform(Bang(name: "setoption", args: ["M", "Attribute", "#stop | stop-color | white"]))
        skin.update()
        t.check(m.revision > firstRevision)
        t.equal(gradient(svgPaths(m.nodes).first?.fill)?.stops.first?.color, .white)
        t.equal(gradient(svgPaths(first.nodes).first?.fill)?.stops.first?.color, RGBA(r: 0, g: 0, b: 255))
    }

    t.suite("SVG: numbered Attribute options target ids, the root and every element") {
        let (_, m) = try meter("<svg width=\"20\" height=\"20\"><rect id=\"r\" width=\"20\" height=\"20\" fill=\"red\"/><circle id=\"c\" cx=\"10\" cy=\"10\" r=\"5\" fill=\"blue\"/></svg>",
                               "Attribute=r | fill | #00ff00\nAttribute2=c | fill | #ffff00\nAttribute3=* | stroke-width | 5\nAttribute4=svg | opacity | 0.5")
        let paths = svgPaths(m.nodes)
        t.equal(paths.count, 2)
        t.equal(paths.first?.fill, .color(RGBA(r: 0, g: 255, b: 0)), "Attribute targets an id without #")
        t.equal(paths.last?.fill, .color(RGBA(r: 255, g: 255, b: 0)), "Attribute2 applies too")
        t.check(paths.allSatisfy { $0.strokeStyle.width == 5 }, "* applies to every element")
        t.check(svgGroups(m.nodes).contains { abs($0.1 - 0.5) < 0.0001 }, "svg targets the root element")
    }

    t.suite("SVG: malformed documents and excessive nesting are harmless") {
        for document in ["<svg><g></svg>", "<html><rect width=\"10\" height=\"10\"/></html>",
                         "<svg>" + String(repeating: "<g>", count: 70) + "<rect width=\"10\" height=\"10\"/>" + String(repeating: "</g>", count: 70) + "</svg>"] {
            let (_, m) = try meter(document)
            t.check(m.nodes.isEmpty)
        }
        let (_, m) = try meter("<svg><path d=\"M0 0L10 0Z123\"/></svg>")
        t.check(svgPaths(m.nodes).count <= 1, "malformed data following a close command always terminates")
    }
}
