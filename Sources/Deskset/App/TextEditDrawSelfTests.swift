import AppKit
import DesksetCore
import DesksetDraw

enum TextEditDrawSelfTests {
    static func run(_ t: AppTestRunner) {
        geometryTests(t)
        paintingTests(t)
    }

    private static var style: TextStyle {
        var result = TextStyle()
        result.fontSize = 12
        result.accurateText = true
        result.antiAlias = false
        return result
    }

    private static func geometryTests(_ t: AppTestRunner) {
        t.suite("Runtime: TextEdit drawing: shaped caret stops, hit tests and selection use UTF-16 clusters") {
            let context = DrawContext(fonts: AppFontResolver())
            let value = "a👩🏽‍💻e\u{301}中z"
            let geometry = context.textEditLayout(value, style: style,
                                                  viewport: SkinRect(width: 400, height: 50),
                                                  multiline: false, cycle: 0)
            var expected = [0], offset = 0
            for character in value { offset += String(character).utf16.count; expected.append(offset) }
            t.equal(geometry.lines.count, 1)
            t.equal(geometry.lines[0].caretStops.map(\.offset), expected,
                    "surrogate pairs, combining marks and joined emoji have no interior editing stops")
            for stop in geometry.lines[0].caretStops {
                let caret = geometry.caretRect(at: stop.offset)
                t.close(caret.x, stop.x)
                t.check(caret.height > 0)
                t.equal(geometry.hitTest(SkinPoint(x: caret.x, y: caret.y + caret.height / 2)), stop.offset)
            }
            t.equal(geometry.hitTest(SkinPoint(x: -100, y: -100)), 0)
            t.equal(geometry.hitTest(SkinPoint(x: 1000, y: 1000)), value.utf16.count)
            let selected = geometry.selectionRects(in: expected[1]..<expected[2])
            t.check(!selected.isEmpty && selected.allSatisfy { $0.width > 0 && $0.height > 0 })
            t.equal(geometry.selectionRects(in: 2..<2), [])
        }

        t.suite("Runtime: TextEdit drawing: empty input and trailing newlines retain real caret line metrics") {
            let context = DrawContext(fonts: AppFontResolver())
            let viewport = SkinRect(width: 100, height: 80)
            let empty = context.textEditLayout("", style: style, viewport: viewport, multiline: true, cycle: 0)
            t.equal(empty.lines.count, 1)
            t.equal(empty.lines[0].range, 0..<0)
            t.equal(empty.lines[0].caretStops.map(\.offset), [0])
            t.check(empty.caretRect(at: 0).height > 0, "the caret does not depend on visible text glyphs")
            for value in ["x\n", "x\r\n", "\n\n"] {
                let layout = context.textEditLayout(value, style: style, viewport: viewport, multiline: true, cycle: 0)
                t.equal(layout.lines.count, value == "\n\n" ? 3 : 2)
                t.equal(layout.lines.last?.range, value.utf16.count..<value.utf16.count)
                t.equal(layout.lines.last?.caretStops.map(\.offset), [value.utf16.count])
                t.check(layout.caretRect(at: value.utf16.count).y > 0)
                t.close(layout.lines.last?.bounds.height ?? 0, empty.lines[0].bounds.height)
            }
            let newline = context.textEditLayout("a\nb", style: style, viewport: viewport, multiline: true, cycle: 0)
            let rectangles = newline.selectionRects(in: 1..<2)
            t.equal(rectangles.count, 1)
            t.close(rectangles.first?.width ?? 0, 1, "a selected newline has a visible caret-width cell")
        }

        t.suite("Runtime: TextEdit drawing: wrapping follows ClipString geometry and preserves soft-wrap affinity") {
            let context = DrawContext(fonts: AppFontResolver())
            let viewport = SkinRect(width: 65, height: 30)
            let value = "one two three four five six"
            var wrapped = style
            wrapped.wrap = true
            wrapped.clip = 1
            let single = context.textEditLayout(value, style: wrapped, viewport: viewport, multiline: false, cycle: 0)
            t.equal(single.lines.count, 1, "a single-line input scrolls horizontally even with ClipString")
            t.check(single.contentSize.width > viewport.width)
            let unwrapped = context.textEditLayout(value, style: style, viewport: viewport, multiline: true, cycle: 0)
            t.equal(unwrapped.lines.count, 1, "Multiline alone does not invent automatic wrapping")
            let layout = context.textEditLayout(value, style: wrapped, viewport: viewport, multiline: true, cycle: 0)
            t.check(layout.lines.count > 2)
            t.check(layout.contentSize.height > viewport.height, "off-screen visual lines are retained for scrolling")
            guard let first = layout.lines.first, first.isSoftWrap else { return t.check(false, "a soft wrap exists") }
            let boundary = first.range.upperBound
            t.equal(layout.lineIndex(at: boundary), 1)
            t.equal(layout.lineIndex(at: boundary, preferredLine: 0), 0)
            t.close(layout.caretRect(at: boundary, preferredLine: 0).y, 0)
            t.check(layout.caretRect(at: boundary).y > 0)
            t.equal(layout.offset(onLine: 0, preferredX: 1000), boundary)
            t.equal(layout.offset(onLine: 1, preferredX: -1000), boundary)
            t.equal(layout.lineIndex(at: boundary, preferredLine: 99), 1, "stale affinities are ignored")
        }

        t.suite("Runtime: TextEdit drawing: aligned overflow remains reachable with nonnegative scroll") {
            let context = DrawContext(fonts: AppFontResolver())
            let viewport = SkinRect(width: 60, height: 15)
            for horizontal in [HorizontalTextAlign.center, .right] {
                for vertical in [VerticalTextAlign.center, .bottom] {
                    var aligned = style
                    aligned.horizontalAlign = horizontal
                    aligned.verticalAlign = vertical
                    let overflow = context.textEditLayout("a very long line\nsecond\nthird", style: aligned,
                                                          viewport: viewport, multiline: true, cycle: 0)
                    t.close(overflow.caretRect(at: 0).x, 0)
                    t.close(overflow.caretRect(at: 0).y, 0)
                    t.check(overflow.contentSize.width > viewport.width)
                    t.check(overflow.contentSize.height > viewport.height)
                    let fitted = context.textEditLayout("a", style: aligned,
                                                       viewport: SkinRect(width: 100, height: 100),
                                                       multiline: true, cycle: 0)
                    t.check(fitted.caretRect(at: 0).x > 0 && fitted.caretRect(at: 0).y > 0,
                            "alignment still applies to content that fits")
                }
            }
        }

        t.suite("Runtime: TextEdit drawing: bidi selections follow glyph runs instead of crossing unrelated text") {
            let context = DrawContext(fonts: AppFontResolver())
            let value = "abc אבג def"
            let layout = context.textEditLayout(value, style: style, viewport: SkinRect(width: 200, height: 40),
                                                multiline: false, cycle: 0)
            let cells = layout.lines.first?.selectionCells ?? []
            t.check(cells.count >= value.count)
            let rtl = layout.selectionRects(in: 4..<7)
            t.equal(rtl.count, 1, "a complete RTL run is a contiguous visual selection")
            let firstRTL = layout.selectionRects(in: 4..<5)
            let lastRTL = layout.selectionRects(in: 6..<7)
            t.check((firstRTL.first?.x ?? 0) > (lastRTL.first?.x ?? 0))
            t.check((firstRTL.first?.width ?? 1000) < (rtl.first?.width ?? 0),
                    "one RTL character does not select the entire run")
        }

        t.suite("Runtime: TextEdit drawing: measurement and drawing reuse one owner-local layout cache") {
            let context = DrawContext(fonts: AppFontResolver())
            let viewport = SkinRect(x: 20, y: 10, width: 90, height: 40)
            let value = "cached text"
            let geometry = context.textEditLayout(value, style: style, viewport: viewport, multiline: false, cycle: 0)
            let builds = context.text.builds
            t.check(builds > 0)
            for cycle in 1...20 {
                t.equal(context.textEditLayout(value, style: style, viewport: viewport,
                                               multiline: false, cycle: cycle), geometry)
                let canvas = try bitmap()
                let draw = TextDraw(text: value, style: style, frame: viewport, contentFrame: viewport,
                                    anchor: SkinPoint(x: viewport.x, y: viewport.y),
                                    editing: TextEditingDraw(isFocused: true, caretOffset: value.utf16.count,
                                                             selectionRange: 0..<0))
                TextRenderer.draw(draw, in: canvas, layouts: context.text, cycle: cycle)
            }
            t.equal(context.text.builds, builds, "caret blink and scroll do not rebuild fonts or attributed text")
            let other = DrawContext(fonts: AppFontResolver())
            _ = other.textEditLayout("", style: style, viewport: viewport, multiline: false, cycle: 0)
            t.equal(context.text.builds, builds, "another owner has an independent cache")
        }
    }

    private static func paintingTests(_ t: AppTestRunner) {
        t.suite("Runtime: TextEdit drawing: focus border, selection and blinking caret paint configured colors") {
            let context = SkinRenderContext()
            let viewport = SkinRect(x: 25, y: 20, width: 100, height: 35)
            var invisible = style
            invisible.color = RGBA(r: 0, g: 0, b: 0, a: 0)
            var editing = TextEditingDraw(isFocused: true, caretOffset: 3, selectionRange: 0..<2,
                                          caretColor: .init(r: 255, g: 0, b: 0),
                                          selectionColor: .init(r: 0, g: 255, b: 0),
                                          focusBorderWidth: 2, focusBorderColor: .init(r: 0, g: 0, b: 255))
            var draw = TextDraw(text: "hello", style: invisible,
                                frame: SkinRect(x: 20, y: 15, width: 110, height: 45), contentFrame: viewport,
                                anchor: SkinPoint(x: 20, y: 15), editing: editing)
            let canvas = try bitmap()
            SkinRenderer.drawString(draw, canvas, context, cycle: 0)
            t.check(count(canvas, color: .init(r: 255, g: 0, b: 0)) > 0)
            t.check(count(canvas, color: .init(r: 0, g: 255, b: 0)) > 0)
            t.check(count(canvas, color: .init(r: 0, g: 0, b: 255)) > 0)
            editing.caretVisible = false
            draw.editing = editing
            let blink = try bitmap()
            SkinRenderer.drawString(draw, blink, context, cycle: 1)
            t.equal(count(blink, color: .init(r: 255, g: 0, b: 0)), 0)
            t.equal(count(blink, color: .init(r: 0, g: 255, b: 0)), count(canvas, color: .init(r: 0, g: 255, b: 0)))
            editing.isFocused = false
            draw.editing = editing
            let blurred = try bitmap()
            SkinRenderer.drawString(draw, blurred, context, cycle: 2)
            t.equal(nontransparent(blurred).count, 0, "blur removes editing decorations")
        }

        t.suite("Runtime: TextEdit drawing: empty input paints its caret independently of placeholder font") {
            let context = SkinRenderContext()
            let viewport = SkinRect(x: 20, y: 15, width: 140, height: 70)
            var placeholderStyle = style
            placeholderStyle.fontSize = 30
            placeholderStyle.color = .init(r: 0, g: 0, b: 255)
            let editing = TextEditingDraw(isFocused: true, caretOffset: 0, selectionRange: 0..<0,
                                          caretColor: .init(r: 255, g: 0, b: 0), layoutText: "", layoutStyle: style)
            let empty = TextDraw(text: "", style: style, frame: viewport, contentFrame: viewport,
                                 anchor: .init(), editing: editing)
            let placeholder = TextDraw(text: "Placeholder", style: placeholderStyle, frame: viewport,
                                       contentFrame: viewport, anchor: .init(), editing: editing)
            let a = try bitmap(), b = try bitmap()
            SkinRenderer.drawString(empty, a, context, cycle: 0)
            SkinRenderer.drawString(placeholder, b, context, cycle: 1)
            t.check(count(a, color: .init(r: 255, g: 0, b: 0)) > 0)
            t.equal(positions(a, color: .init(r: 255, g: 0, b: 0)),
                    positions(b, color: .init(r: 255, g: 0, b: 0)),
                    "the placeholder never changes the input caret's font metrics")
            t.check(count(b, color: .init(r: 0, g: 0, b: 255)) > 0)
        }

        t.suite("Runtime: TextEdit drawing: scroll translates real text and selection inside the content clip") {
            let context = SkinRenderContext()
            let viewport = SkinRect(x: 20, y: 15, width: 60, height: 25)
            var invisible = style
            invisible.color = .init(r: 0, g: 0, b: 0, a: 0)
            let geometry = context.drawing.textEditLayout("abcdef", style: invisible, viewport: viewport,
                                                          multiline: false, cycle: 0)
            let scroll = geometry.caretRect(at: 2).x
            var draw = TextDraw(text: "abcdef", style: invisible, frame: viewport, contentFrame: viewport,
                                anchor: .init(), editing: TextEditingDraw(isFocused: true, caretVisible: false,
                                    caretOffset: 6, selectionRange: 2..<4,
                                    selectionColor: .init(r: 0, g: 255, b: 0)))
            let before = try bitmap(), after = try bitmap()
            SkinRenderer.drawString(draw, before, context, cycle: 0)
            draw.editing?.scroll.x = scroll
            SkinRenderer.drawString(draw, after, context, cycle: 1)
            let a = positions(before, color: .init(r: 0, g: 255, b: 0))
            let b = positions(after, color: .init(r: 0, g: 255, b: 0))
            t.check(!a.isEmpty && !b.isEmpty)
            t.check((a.map { $0 % 200 }.min() ?? 0) > (b.map { $0 % 200 }.min() ?? 0))
            for pixel in nontransparent(after) {
                let x = pixel % 200, y = pixel / 200
                t.check(x >= 20 && x < 80 && y >= 15 && y < 40, "the viewport clips all editing pixels")
            }
            var text = style
            text.color = .init(r: 20, g: 30, b: 40)
            text.clip = 1
            draw.text = "a long overflowing text value"
            draw.style = text
            draw.editing?.selectionRange = 0..<0
            let original = try bitmap(), scrolled = try bitmap()
            draw.editing?.scroll.x = 0
            SkinRenderer.drawString(draw, original, context, cycle: 2)
            draw.editing?.scroll.x = 35
            SkinRenderer.drawString(draw, scrolled, context, cycle: 3)
            t.check(bytes(original) != bytes(scrolled), "overflow paints later glyphs after horizontal scrolling")
            t.check(nontransparent(original).allSatisfy { viewport.contains(x: Double($0 % 200), y: Double($0 / 200)) })
            t.check(nontransparent(scrolled).allSatisfy { viewport.contains(x: Double($0 % 200), y: Double($0 / 200)) })
        }

        t.suite("Runtime: TextEdit drawing: vertical scroll keeps later explicit lines and has no ellipsis") {
            let context = SkinRenderContext()
            let viewport = SkinRect(x: 10, y: 10, width: 100, height: 30)
            let full = "first line\nsecond line\nthird line"
            let layout = context.drawing.textEditLayout(full, style: style, viewport: viewport,
                                                        multiline: true, cycle: 0)
            let offset = layout.lines[1].bounds.y
            var draw = TextDraw(text: full, style: style, frame: viewport, contentFrame: viewport, anchor: .init(),
                                editing: TextEditingDraw(isFocused: false, caretOffset: 0, selectionRange: 0..<0,
                                                         scroll: SkinPoint(y: offset), multiline: true))
            let actual = try bitmap(), reference = try bitmap()
            SkinRenderer.drawString(draw, actual, context, cycle: 0)
            draw.text = "second line\nthird line"
            draw.editing?.scroll.y = 0
            SkinRenderer.drawString(draw, reference, context, cycle: 1)
            t.equal(bytes(actual), bytes(reference), "scrolling draws all real retained lines without truncation glyphs")
        }

        t.suite("Runtime: TextEdit drawing: captured values keep clipping and text matrix confined") {
            let context = SkinRenderContext()
            var draw = TextDraw(text: "frozen", style: style, frame: SkinRect(x: 20, y: 20, width: 100, height: 40),
                                contentFrame: SkinRect(x: 25, y: 25, width: 90, height: 30), anchor: .init(),
                                editing: TextEditingDraw(isFocused: true, caretOffset: 2, selectionRange: 0..<2))
            let frozen = draw
            let before = try bitmap(), after = try bitmap()
            let matrix = CGAffineTransform(a: 1.2, b: 0.1, c: 0.2, d: 0.8, tx: 4, ty: 5)
            before.textMatrix = matrix
            SkinRenderer.drawString(frozen, before, context, cycle: 0)
            t.equal(before.textMatrix, matrix, "CoreText's text matrix is restored explicitly")
            draw.text = "changed"
            draw.editing?.caretOffset = 7
            draw.editing?.scroll = .init(x: 20, y: 10)
            SkinRenderer.drawString(frozen, after, SkinRenderContext(), cycle: 100)
            t.equal(bytes(before), bytes(after), "a fresh cache replays the immutable captured drawing")
            before.setFillColor(NSColor.red.cgColor)
            before.fill(CGRect(x: 1, y: 1, width: 2, height: 2))
            t.check(count(before, color: .init(r: 255, g: 0, b: 0)) > 0, "the editing clip does not leak to later items")
        }
    }

    private static func bitmap() throws -> CGContext {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 800,
                                     space: space, bitmapInfo: info) else { throw CocoaError(.coderInvalidValue) }
        canvas.clear(CGRect(x: 0, y: 0, width: 200, height: 120))
        canvas.translateBy(x: 0, y: 120)
        canvas.scaleBy(x: 1, y: -1)
        return canvas
    }

    private static func bytes(_ canvas: CGContext) -> Data {
        guard let data = canvas.data else { return Data() }
        return Data(bytes: data, count: canvas.bytesPerRow * canvas.height)
    }

    private static func positions(_ canvas: CGContext, color: RGBA) -> [Int] {
        guard let bytes = canvas.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var result: [Int] = []
        for y in 0..<canvas.height {
            for x in 0..<canvas.width {
                let p = bytes + y * canvas.bytesPerRow + x * 4
                if Double(p[0]) == color.b, Double(p[1]) == color.g,
                   Double(p[2]) == color.r, Double(p[3]) == color.a { result.append(y * 200 + x) }
            }
        }
        return result
    }

    private static func count(_ canvas: CGContext, color: RGBA) -> Int { positions(canvas, color: color).count }

    private static func nontransparent(_ canvas: CGContext) -> [Int] {
        guard let bytes = canvas.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        return (0..<(canvas.width * canvas.height)).filter {
            bytes[($0 / canvas.width) * canvas.bytesPerRow + ($0 % canvas.width) * 4 + 3] != 0
        }
    }
}
