import AppKit
import CoreText
import DeskLanguage
import DesksetCore
import DesksetDraw

/// The source, compiler and program use actual Core Text measurement and the shared drawing executor.
/// No Skin, INI document, service or window is created. These are bitmap checks, not compositor acceptance.
enum DeskProgramDrawingSelfTests {
    private enum Failure: Error { case compilation, bitmap }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk program drawing: checked text uses point fonts and matches native drawing") {
            let source = #"widget { Text("Desk 中文 😀").font(20).color(.accent).padding(4) }"#
            let program = try compile(source, t)
            let text = "Desk 中文 😀"
            for appearance in [SkinAppearance.light, .dark] {
                let context = DrawContext(fonts: AppFontResolver())
                var runtime = try ProgramRuntime(program: program)
                let scene = try runtime.project(environment: environment(appearance)) { value, style, width in
                    t.equal(value, text)
                    t.equal(width, nil)
                    t.close(CTFontGetSize(AppFontResolver().resolve(FontRequest(style: style)).font), 20,
                            "the native font is 20 points, without applying the legacy size conversion twice")
                    let layout = context.text.layout(value, style: style, wrapWidth: width.map { CGFloat($0) }, cycle: 1)
                    t.close(layout.pad, 0, "Desk text does not inherit compatibility padding")
                    return SkinSize(width: layout.size.width, height: layout.size.height)
                }
                let style = referenceStyle(points: 20, color: appearance.accentColor)
                let size = context.text.layout(text, style: style, wrapWidth: nil, cycle: 1).size
                let frame = SkinRect(width: size.width + 8, height: size.height + 8)
                let content = SkinRect(x: 4, y: 4, width: size.width, height: size.height)
                let expected = TextDraw(text: text, style: style, frame: frame, contentFrame: content, anchor: SkinPoint())
                t.equal(scene.size, SkinSize(width: frame.width, height: frame.height))
                t.equal(scene.drawingItems, [.text(expected)], "the compiled geometry and style match the explicit native recipe")
                for scale in [1, 2] {
                    let actual = try pixels(scene.drawingItems, size: scene.size, scale: scale, context: context)
                    let reference = try pixels([.text(expected)], size: scene.size, scale: scale,
                                               context: DrawContext(fonts: AppFontResolver()))
                    t.check(stride(from: 3, to: actual.count, by: 4).contains { actual[$0] != 0 }, "native text produces visible pixels")
                    t.equal(actual, reference, "compiled / explicit native RGBA bytes at \(scale)x")
                    let cold = try pixels(scene.drawingItems, size: scene.size, scale: scale,
                                          context: DrawContext(fonts: AppFontResolver()))
                    t.equal(cold, actual, "the program scene replays with independent font/layout caches")
                }
            }
        }

        t.suite("App: Desk program drawing: hidden text keeps native layout space without painting") {
            let program = try compile(#"widget { Column(spacing: 3, align: .left) { Text("first").font(13).hidden(); Text("中文 😀").font(20) } }"#, t)
            let context = DrawContext(fonts: AppFontResolver())
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: environment(.light)) { text, style, width in
                let size = context.text.layout(text, style: style, wrapWidth: width.map { CGFloat($0) }, cycle: 1).size
                return SkinSize(width: size.width, height: size.height)
            }
            let first = context.text.layout("first", style: referenceStyle(points: 13, color: SkinAppearance.light.labelColor),
                                            wrapWidth: nil, cycle: 1).size
            let style = referenceStyle(points: 20, color: SkinAppearance.light.labelColor)
            let second = context.text.layout("中文 😀", style: style, wrapWidth: nil, cycle: 1).size
            let frame = SkinRect(x: 0, y: first.height + 3, width: second.width, height: second.height)
            let expected = TextDraw(text: "中文 😀", style: style, frame: frame, contentFrame: frame,
                                    anchor: SkinPoint(x: 0, y: first.height + 3))
            t.equal(scene.size, SkinSize(width: max(first.width, second.width), height: first.height + 3 + second.height))
            t.equal(scene.elements.count, 3)
            t.equal(scene.elements[1].visibility, .hiddenKeepsSpace)
            t.equal(scene.drawingItems, [.text(expected)])
            for scale in [1, 2] {
                let actual = try pixels(scene.drawingItems, size: scene.size, scale: scale, context: context)
                let reference = try pixels([.text(expected)], size: scene.size, scale: scale,
                                           context: DrawContext(fonts: AppFontResolver()))
                t.check(stride(from: 3, to: actual.count, by: 4).contains { actual[$0] != 0 })
                t.equal(actual, reference, "only the visible child paints, at its native measured offset")
            }
        }
    }

    private static func compile(_ source: String, _ t: AppTestRunner) throws -> WidgetProgram {
        let checked = Desk.check(Desk.parse(source, fileName: "NativeText.desk"))
        let result = Desk.compile(checked)
        t.check(!result.diagnostics.contains { $0.severity == .error }, "the native fixture passes the real checker")
        t.check(result.issues.isEmpty, "\(result.issues)")
        guard let program = result.program else { throw Failure.compilation }
        return program
    }

    private static func environment(_ appearance: SkinAppearance) -> EnvironmentStamp {
        EnvironmentStamp(scale: 1, fontGeneration: 0, appearance: AppearanceStamp(value: appearance, name: "native fixture"),
                         imageGeneration: 0)
    }

    /// Explicit renderer-side values, independent of the program's style adapter.
    private static func referenceStyle(points: Double, color: RGBA) -> TextStyle {
        var style = TextStyle()
        style.fontFace = "System"
        style.fontSize = points * 0.75
        style.fontWeight = 400
        style.color = color
        style.horizontalAlign = .center
        style.verticalAlign = .center
        style.accurateText = true
        style.antiAlias = true
        style.trailingSpaces = true
        return style
    }

    private static func pixels(_ items: [DrawItem], size: SkinSize, scale: Int, context: DrawContext) throws -> Data {
        let width = Int(ceil(size.width * Double(scale))), height = Int(ceil(size.height * Double(scale)))
        guard width > 0, height > 0, width <= 1024, height <= 1024,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = canvas.data else { throw Failure.bitmap }
        canvas.clear(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        DesksetDraw.DrawExecutor.draw(items, in: canvas, context: context, cycle: 1,
                          target: DrawTarget.prepareOwnedBitmap(canvas, glass: .none))
        var result = Data(capacity: width * height * 4)
        for row in 0..<height {
            result.append(bytes.advanced(by: row * canvas.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return result
    }
}
