import AppKit
import CoreText
import DesksetCore
import DesksetDraw

enum DrawFontSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("Runtime: font boundary: requests keep point conversion, defaults and mutable inline settings") {
            var style = TextStyle()
            style.fontFace = "Segoe UI"
            style.fontWeight = 450
            style.bold = true
            style.italic = true
            for (points, pixels) in [(-1.0, 0.01), (0, 0.01), (0.001, 0.01), (9, 12), (18, 24)] {
                style.fontSize = points
                let request = FontRequest(style: style)
                t.equal(request.face, "Segoe UI")
                t.close(request.size, CGFloat(pixels))
                t.equal(request.weight, 450)
                t.check(request.bold && request.italic && !request.oblique)
                t.check(request.stretch == nil && request.features.isEmpty)
            }
            var request = FontRequest(face: "Arial", size: 16)
            t.check(request.weight == nil && !request.bold && !request.italic && !request.oblique)
            request.face = "Times New Roman"
            request.size = 24
            request.weight = 700
            request.bold = true
            request.italic = true
            request.oblique = true
            request.stretch = 3
            var feature = FontFeature(tag: "liga", value: 1)
            feature.value = 0
            request.features.append(feature)
            t.equal(request, FontRequest(face: "Times New Roman", size: 24, weight: 700, bold: true, italic: true,
                                         oblique: true, stretch: 3, features: [FontFeature(tag: "liga", value: 0)]))
            t.equal(Set([request, request]).count, 1, "requests remain cache keys across the module boundary")
            var metrics = FontLineMetrics(ascent: 20, descent: 5, leading: 0)
            metrics.leading = 2
            t.equal(metrics, FontLineMetrics(ascent: 20, descent: 5, leading: 2))
        }

        t.suite("Runtime: font boundary: layouts register through their resolver and follow its generation") {
            let resolver = TestResolver(result: resolved(size: 16))
            resolver.advanceOnRegistration = true
            let cache = TextLayoutCache(fonts: resolver)
            var style = TextStyle()
            style.accurateText = true
            style.fontFolder = "/font-boundary-fixture"
            let first = cache.layout("Measured text", style: style, wrapWidth: nil, cycle: 0)
            t.equal(Array(resolver.events.prefix(2)), ["register:/font-boundary-fixture", "generation"],
                    "registration happens before reading the generation for the cache key")
            t.equal(resolver.value, 1)
            let resolvedBeforeHit = resolver.requests.count
            t.check(resolvedBeforeHit > 0)
            t.check(cache.layout("Measured text", style: style, wrapWidth: nil, cycle: 0) === first)
            t.equal(cache.builds, 1, "the layout is cached under the post-registration generation")
            t.equal(resolver.requests.count, resolvedBeforeHit, "a hit does not resolve fonts again")

            resolver.result = resolved(size: 32)
            resolver.value += 1
            let changed = cache.layout("Measured text", style: style, wrapWidth: nil, cycle: 0)
            t.check(changed !== first, "the injected generation invalidates the layout")
            t.equal(cache.builds, 2)
            t.check(changed.textWidth > first.textWidth && changed.textHeight > first.textHeight,
                    "the rebuilt layout uses the injected replacement font")
            t.check(cache.layout("Measured text", style: style, wrapWidth: nil, cycle: 0) === changed)
            t.equal(cache.builds, 2)
            t.equal(resolver.registered, Array(repeating: "/font-boundary-fixture", count: 4))
        }

        t.suite("Runtime: font boundary: complete font results reach shaping and line metrics") {
            let metrics = FontLineMetrics(ascent: 31, descent: 7, leading: 3)
            let resolver = TestResolver(result: resolved(size: 16, bold: true, slant: 0.2, metrics: metrics))
            let cache = TextLayoutCache(fonts: resolver)
            var style = TextStyle()
            style.accurateText = true
            let layout = cache.layout("Text", style: style, wrapWidth: nil, cycle: 0)
            let attributes = layout.attributed.attributes(at: 0, effectiveRange: nil)
            t.equal(attributes[NSAttributedString.Key("deskset.bold")] as? Bool, true,
                    "synthetic bold survives the resolver boundary")
            t.close(attributes[NSAttributedString.Key("deskset.slant")] as? CGFloat ?? 0, 0.2)
            t.equal(attributes[NSAttributedString.Key("deskset.metrics")] as? [CGFloat], [31, 7, 3])
            t.equal(attributes[NSAttributedString.Key("deskset.metricsFont")] as? String,
                    CTFontCopyPostScriptName(resolver.result.font) as String)
            t.close(layout.lines.first?.ascent ?? 0, 31)
            t.close(layout.lines.first?.descent ?? 0, 7)
            t.close(layout.lines.first?.leading ?? 0, 3)
            t.close(layout.textHeight, 41, "substitution metrics determine layout height")
            let blank = cache.layout("\n", style: style, wrapWidth: nil, cycle: 0)
            t.close(blank.textHeight, 41, "empty lines also use the resolver's complete base result")

            resolver.result = resolved(size: 16, map: [0x61: 0x2713])
            resolver.value += 1
            style.fontFace = "Marlett"
            let mapped = cache.layout("ab", style: style, wrapWidth: nil, cycle: 0)
            t.equal(mapped.attributed.string, "✓b", "Marlett's character map is applied before shaping")
        }

        t.suite("Runtime: font boundary: inline fonts resolve through the same injected service") {
            let resolver = TestResolver(result: resolved(size: 16))
            let cache = TextLayoutCache(fonts: resolver)
            var style = TextStyle()
            style.fontFace = "Base"
            style.fontSize = 12
            style.fontWeight = 425
            style.bold = true
            style.italic = true
            style.inlineSpans = [
                .init(location: 1, length: 1, setting: .face("Inline")),
                .init(location: 1, length: 1, setting: .size(18)),
                .init(location: 1, length: 1, setting: .weight(650)),
                .init(location: 1, length: 1, setting: .oblique),
                .init(location: 1, length: 1, setting: .stretch(3)),
                .init(location: 1, length: 1, setting: .typography(feature: "liga", value: 0)),
            ]
            _ = cache.layout("ab", style: style, wrapWidth: nil, cycle: 0)
            t.check(resolver.requests.contains(FontRequest(style: style)), "the base uses the injected service")
            t.check(resolver.requests.contains(FontRequest(face: "Inline", size: 24, weight: 650, bold: true,
                                                           italic: true, oblique: true, stretch: 3,
                                                           features: [FontFeature(tag: "liga", value: 0)])),
                    "inline face, size, weight, slant, stretch and typography reach it too")
        }

        t.suite("Runtime: font boundary: the app adapter preserves existing resolution and registration") {
            let resolver: any FontResolving = AppFontResolver()
            for request in [FontRequest(face: "Arial", size: 16, bold: true),
                            FontRequest(face: "Segoe UI", size: 20),
                            FontRequest(face: "System Rounded", size: 16, italic: true),
                            FontRequest(face: "Marlett", size: 16)] {
                let expected = Fonts.resolve(request)
                let actual = resolver.resolve(request)
                t.check(CFEqual(actual.font, expected.font), request.face)
                t.equal(actual.syntheticBold, expected.syntheticBold, request.face)
                t.equal(actual.slant, expected.slant, request.face)
                t.equal(actual.characterMap, expected.characterMap, request.face)
                t.equal(actual.lineMetrics, expected.lineMetrics, request.face)
            }
            let missing = t.temporaryDirectory("draw-fonts").appendingPathComponent("missing-fonts").path
            resolver.registerFolder(missing)
            t.check(Fonts.isRememberedAsMissing(missing), "registration still belongs to the existing app service")
            t.equal(resolver.generation, Fonts.generation)
        }
    }

    private static func resolved(size: CGFloat, bold: Bool = false, slant: CGFloat = 0,
                                 map: [UInt16: UInt16]? = nil, metrics: FontLineMetrics? = nil) -> ResolvedFont {
        ResolvedFont(font: CTFontCreateWithName("Helvetica" as CFString, size, nil), syntheticBold: bold,
                     characterMap: map, slant: slant, lineMetrics: metrics)
    }

    private final class TestResolver: FontResolving {
        var value = 0
        var result: ResolvedFont
        var advanceOnRegistration = false
        var registered: [String] = []
        var requests: [FontRequest] = []
        var events: [String] = []

        init(result: ResolvedFont) { self.result = result }

        var generation: Int {
            events.append("generation")
            return value
        }

        func registerFolder(_ folder: String) {
            registered.append(folder)
            events.append("register:" + folder)
            if advanceOnRegistration {
                value += 1
                advanceOnRegistration = false
            }
        }

        func resolve(_ request: FontRequest) -> ResolvedFont {
            requests.append(request)
            events.append("resolve:" + request.face)
            return result
        }
    }
}
