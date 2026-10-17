import Foundation
import ImageIO
@testable import DesksetCore

// A skin's hit map (suite prefix "Skin threading: hit map"; docs/skin-threading.md §5.5, phase 2 step 2). The window of
// a skin that runs on a thread of its own answers AppKit's mouse questions from the hit map the skin published last,
// not from the skin. These suites check that its answers are the live skin's — for every mouse action kind, the Button
// under the pointer, the cursor, the tooltip and the drag area — on a grid of points, in every test and default skin,
// after updates and after the bangs that change what the mouse finds. The hit map is built again only when the skin's
// snapshot generation moved, as the app does: a change the generation misses shows up as a stale answer.

func runHitMapTests(_ t: TestRunner) {
    CorePlugins.register()
    runHitMapUnitTests(t)
    runHitMapCorpusTests(t)
}

// MARK: - Helpers

/// Real image sizes, and pixels whose alpha follows a fixed pattern (so Buttons have transparent pixels to test);
/// otherwise `FakeHost`'s answers.
final class HitMapHost: SkinHost, SkinImageQueries {
    private var sizes: [String: (width: Double, height: Double)?] = [:]
    private let fake = FakeHost()
    /// How many times the engine said a piece of work ended.
    var finishedWork = 0

    func skinNeedsDisplay(_ skin: Skin) {}
    func skin(_ skin: Skin, handle bang: Bang) -> Bool { fake.skin(skin, handle: bang) }
    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {}
    func skin(_ skin: Skin, execute target: String, arguments: [String]) {}
    func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {}
    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
        fake.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
    }
    func environment(for skin: Skin) -> SkinEnvironment { SkinEnvironment() }

    func imageSize(atPath path: String) -> (width: Double, height: Double)? {
        if let known = sizes[path] { return known }
        var size: (width: Double, height: Double)?
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double {
            size = (w, h)
        } else {
            size = fake.imageSize(atPath: path)
        }
        sizes[path] = size
        return size
    }

    func imageExifOrientation(atPath path: String) -> Int { 1 }

    /// Transparent on a diagonal pattern and in the top-left 3×3 corner of every image.
    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        if x < 3 && y < 3 { return 0 }
        return (x * 7 + y * 3) % 5 == 0 ? 0 : 255
    }

    func skinDidFinishWork(_ skin: Skin) { finishedWork += 1 }
}

private var hitMapHosts: [HitMapHost] = []

/// An image service independent of any skin or host, with observable pixel queries.
private final class HitMapPixels: SkinImageQueries {
    struct Query: Equatable {
        let path: String
        let x: Int
        let y: Int
        let oriented: Bool
    }

    let alpha: (Int, Int) -> Double?
    var queries: [Query] = []

    init(_ alpha: @escaping (Int, Int) -> Double?) { self.alpha = alpha }

    func imageExifOrientation(atPath path: String) -> Int { 1 }

    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        queries.append(Query(path: path, x: x, y: y, oriented: exifOriented))
        return alpha(x, y)
    }
}

/// `makeSkin` with a `HitMapHost` (kept alive for the run: `Skin.host` is weak).
func makeHitMapSkin(_ t: TestRunner, _ ini: String) throws -> (Skin, HitMapHost) {
    let host = HitMapHost()
    hitMapHosts.append(host)
    let skins = t.temporaryDirectory("hitmap").appendingPathComponent("Skins")
    let dir = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try ini.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
    let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                    system: FakeSystem(), host: host)
    try skin.load()
    return (skin, host)
}

/// Keeps a hit map as the app does: built again only when the skin's snapshot generation moved.
struct HitMapFollower {
    let skin: Skin
    private(set) var map: SkinHitMap
    private var generation: Int
    private(set) var rebuilds = 0

    init(_ skin: Skin) {
        self.skin = skin
        map = skin.makeHitMap()
        generation = skin.snapshotGeneration
    }

    mutating func refresh() {
        guard skin.snapshotGeneration != generation else { return }
        generation = skin.snapshotGeneration
        map = skin.makeHitMap()
        rebuilds += 1
    }
}

/// Points to test a skin at: a grid over the skin and a margin around it, and for every meter the mouse can find its
/// corners, edges, centre and a few points inside (Shapes and Buttons have holes).
func hitMapPoints(_ skin: Skin, _ map: SkinHitMap, grid: Int = 12, meters: Int = 12) -> [(Double, Double)] {
    var points: [(Double, Double)] = []
    let w = max(skin.width, 1), h = max(skin.height, 1)
    for i in 0...grid {
        for j in 0...grid {
            points.append((-6 + Double(i) * (w + 12) / Double(grid) + 0.25, -6 + Double(j) * (h + 12) / Double(grid) + 0.25))
        }
    }
    var frames = map.entries.map(\.frame)
    frames += map.entries.compactMap(\.glass?.rect)
    for f in frames.prefix(meters) where f.x.isFinite && f.y.isFinite && f.width < 5000 && f.height < 5000 {
        for fx in [-0.5, 0, 0.3, 0.5, 0.999, 1.0] {
            for fy in [-0.5, 0, 0.5, 0.7, 0.999, 1.0] {
                points.append((f.x + fx * f.width, f.y + fy * f.height))
            }
        }
        // Whole pixels of a small image (a Button's corner).
        for dx in 0..<3 { for dy in 0..<3 { points.append((f.x + Double(dx) * 2 + 0.5, f.y + Double(dy) * 2 + 0.5)) } }
    }
    return points
}

/// Compares every answer of `map` with the live skin at `points`; returns the differences (at most `limit`).
/// `allKinds`: `hasAction` for every kind of mouse action, else for those the skin's sections define (the others are
/// never there, and a meter missing from the map shows in the kinds it defines).
func hitMapDifferences(_ skin: Skin, _ map: SkinHitMap, _ points: [(Double, Double)], allKinds: Bool = true,
                       limit: Int = 8) -> [String] {
    var found: [String] = []
    func note(_ what: String) { if found.count < limit { found.append(what) } }
    var kinds = Set(skin.meters.flatMap { $0.mouseActions.keys })
    kinds.formUnion(skin.rainmeterSection?.mouseActions.keys ?? [:].keys)
    let tested = allKinds ? MouseEventKind.allCases : MouseEventKind.allCases.filter(kinds.contains)
    let images = skin.host as? SkinImageQueries
    for (x, y) in points {
        let at = "at (\(x), \(y))"
        for kind in tested where map.hasAction(kind, x: x, y: y, images: images) != skin.hasAction(kind, x: x, y: y) {
            note("hasAction(\(kind.rawValue)) \(at): map \(map.hasAction(kind, x: x, y: y, images: images))")
        }
        if map.isOnButton(x: x, y: y, images: images) != skin.isOnButton(x: x, y: y) { note("isOnButton \(at)") }
        let cursor = skin.mouseCursorName(at: x, y)
        if map.mouseCursorName(at: x, y, images: images) != cursor {
            note("mouseCursorName \(at): map \(String(describing: map.mouseCursorName(at: x, y, images: images))), live \(String(describing: cursor))")
        }
        let pointer = skin.pointerCursorName(x: x, y: y)
        if map.pointerCursorName(at: x, y, images: images) != pointer {
            note("pointerCursorName \(at): map \(String(describing: map.pointerCursorName(at: x, y, images: images))), live \(String(describing: pointer))")
        }
        if map.toolTipInfo(at: x, y, images: images) != skin.toolTipInfo(at: x, y) {
            note("toolTipInfo \(at): map \(String(describing: map.toolTipInfo(at: x, y, images: images)?.text)), live \(String(describing: skin.toolTipInfo(at: x, y)?.text))")
        }
        if map.isInDragArea(x: x, y: y) != skin.isInDragArea(x: x, y: y) { note("isInDragArea \(at)") }
    }
    if map.toolTipAreas != skin.toolTipAreas() { note("toolTipAreas") }
    return found
}

// MARK: - Focused cases

func runHitMapUnitTests(_ t: TestRunner) {
    t.suite("Skin threading: hit map queries use the supplied image service") {
        let frame = SkinRect(x: 10, y: 20, width: 4, height: 3)
        let button = ButtonMouseShape(path: "Strip.png", destination: frame, frameWidth: 4, frameHeight: 3,
                                      flipHorizontal: true, flipVertical: true,
                                      normalSource: SkinRect(x: 0, y: 0, width: 4, height: 3),
                                      shownSource: SkinRect(x: 4, y: 0, width: 4, height: 3), exifOriented: true)
        let entry = SkinHitMap.Entry(name: "Button", frame: frame, shape: .button(button), container: nil,
                                     glass: nil, isButton: true, actions: [:], cursor: true,
                                     cursorName: "CROSS", toolTip: nil)
        var map = SkinHitMap()
        map.entries = [entry]
        let original = map
        let transparent = HitMapPixels { _, _ in 0 }
        let shown = HitMapPixels { x, _ in x == 7 ? 255 : 0 }
        let unknown = HitMapPixels { _, _ in nil }
        t.check(!map.isOnButton(x: 10.25, y: 20.5, images: transparent))
        t.check(map.isOnButton(x: 10.25, y: 20.5, images: shown), "the shown frame can supply the opaque pixel")
        t.equal(shown.queries, [HitMapPixels.Query(path: "Strip.png", x: 3, y: 2, oriented: true),
                               HitMapPixels.Query(path: "Strip.png", x: 7, y: 2, oriented: true)],
                "normal and shown frames keep rounding, both flips and EXIF orientation")
        t.check(map.isOnButton(x: 10.25, y: 20.5, images: nil), "no service means unknown, hence opaque")
        t.check(map.isOnButton(x: 10.25, y: 20.5, images: unknown), "unknown alpha is opaque too")
        t.equal(map.pointerCursorName(at: 10.25, 20.5, images: transparent), nil)
        t.equal(map.pointerCursorName(at: 10.25, 20.5, images: shown), "CROSS")
        t.check(!map.handles(.leftDown, x: 10.25, y: 20.5, images: transparent))
        t.check(map.handles(.leftDown, x: 10.25, y: 20.5, images: shown))
        t.check(map.topButton(at: 10.25, 20.5, images: transparent) === entry,
                "choosing the top Button still uses its frame")
        t.check(map.isHit(entry, x: 10.25, y: 20.5, images: transparent), "ordinary Button actions use the frame")
        t.check(!map.isHit(entry, x: 10.25, y: 20.5, precise: true, images: transparent))
        t.check(map.isHit(entry, x: 10.25, y: 20.5, precise: true, images: shown))
        t.equal(map, original, "changing the query service does not change the map's values")
    }

    t.suite("Skin threading: hit map container pixels govern actions, cursors and tooltips") {
        let frame = SkinRect(x: 0, y: 0, width: 4, height: 3)
        let button = ButtonMouseShape(path: "Mask.png", destination: frame, frameWidth: 4, frameHeight: 3,
                                      flipHorizontal: false, flipVertical: false, normalSource: frame,
                                      shownSource: nil, exifOriented: false)
        let tip = ToolTipInfo(text: "Inside")
        let entry = SkinHitMap.Entry(name: "Inside", frame: frame, shape: .rect(frame), container: .button(button),
                                     glass: nil, isButton: false, actions: [.leftUp: .runs], cursor: true,
                                     cursorName: "TEXT", toolTip: tip)
        var map = SkinHitMap()
        map.entries = [entry]
        let transparent = HitMapPixels { _, _ in 0 }
        let opaque = HitMapPixels { _, _ in 255 }
        for images in [transparent, opaque] {
            let visible = images === opaque
            t.equal(map.isHit(entry, x: 1, y: 1, images: images), visible)
            t.equal(map.isHit(entry, x: 1, y: 1, precise: false, images: images), visible)
            t.equal(map.entry(at: 1, 1, handling: .leftUp, images: images)?.name, visible ? "Inside" : nil)
            t.equal(map.hasAction(.leftUp, x: 1, y: 1, images: images), visible)
            t.equal(map.handles(.leftUp, x: 1, y: 1, images: images), visible)
            t.equal(map.mouseCursorName(at: 1, 1, images: images), visible ? "TEXT" : nil)
            t.equal(map.pointerCursorName(at: 1, 1, images: images), visible ? "TEXT" : nil)
            t.equal(map.toolTipInfo(at: 1, 1, images: images), visible ? tip : nil)
        }
        t.check(transparent.queries.allSatisfy { !$0.oriented }, "the container keeps its orientation policy")
        t.equal(map.entry(at: 1, 1, handling: .leftUp, images: nil)?.name, "Inside")
        t.equal(map.toolTipInfo(at: 1, 1, images: nil), tip)
    }

    t.suite("Skin threading: hit map answers as the skin does for each kind of meter") {
        let (skin, _) = try makeHitMapSkin(t, """
            [Rainmeter]
            Update=1000
            DragMargins=5,5,-10,0
            RightMouseUpAction=[!Log skin]
            MouseActionCursorName=TEXT

            [Variables]
            A=1

            [MeasureCalc]
            Measure=Calc
            Formula=Counter

            [Back]
            Meter=Image
            W=200
            H=120
            SolidColor=0,0,0,1
            LeftMouseDownAction=[!Log down]
            ToolTipText=Back

            [Caught]
            Meter=Image
            X=10
            Y=10
            W=30
            H=30
            LeftMouseDownAction=[]
            LeftMouseUpAction=[ ][]

            [NoCursor]
            Meter=Image
            X=40
            Y=10
            W=20
            H=20

            [NoCursorLater]
            Meter=Image
            X=40
            Y=10
            W=10
            H=10
            MouseActionCursor=0

            [Disc]
            Meter=Shape
            X=70
            Y=10
            Shape=Ellipse 20,20,20 | Fill Color 255,0,0,255 | StrokeWidth 0
            LeftMouseUpAction=[!Log disc]
            MouseActionCursorName=CROSS
            ToolTipText=Disc
            ToolTipTitle=Title

            [Turned]
            Meter=Shape
            X=120
            Y=10
            Shape=Rectangle 0,0,30,20 | Fill Color 0,0,255,255 | StrokeWidth 0
            TransformationMatrix=0.7;0.7;-0.7;0.7;0;0
            MiddleMouseUpAction=[!Log turned]

            [Flat]
            Meter=Shape
            X=160
            Y=10
            Shape=Rectangle 0,0,30,20 | Fill Color 0,0,255,255
            TransformationMatrix=1;0;1;0;0;0
            MiddleMouseUpAction=[!Log flat]

            [Box]
            Meter=Image
            X=10
            Y=60
            W=40
            H=40
            SolidColor=0,0,0,255

            [Inside]
            Meter=Shape
            Container=Box
            X=10
            Y=10
            W=60
            H=60
            Shape=Rectangle 0,0,60,60 | Fill Color 0,255,0,255
            X1MouseUpAction=[!Log inside]
            ToolTipText=Inside

            [Glassy]
            Meter=String
            X=100
            Y=70
            W=20
            H=10
            MacGlass=Regular
            MacGlassCornerRadius=5
            TransformationMatrix=1;0;0;1;15;5
            MouseScrollUpAction=[!Log glass]
            """)
        skin.update()
        skin.update()
        var follower = HitMapFollower(skin)
        let points = hitMapPoints(skin, follower.map, grid: 30)
        t.equal(hitMapDifferences(skin, follower.map, points), [])
        t.equal(follower.map.entries.map(\.name), ["Glassy", "Inside", "Flat", "Turned", "Disc", "NoCursorLater",
                                                  "Caught", "Back"], "top first, only what the mouse finds")
        t.check(!follower.map.toolTipsReadMeasures)
        let images = skin.host as? SkinImageQueries
        t.equal(follower.map.handles(.leftDown, x: 20, y: 20, images: images), true, "caught by []")
        t.equal(follower.map.handles(.rightUp, x: 150, y: 110, images: images), true, "the skin's own action")
        t.equal(follower.map.handles(.middleUp, x: 150, y: 110, images: images), false)
        t.equal(follower.map.pointerCursorName(at: 20, 20, images: images), nil, "caught actions: the arrow")
        t.equal(follower.map.pointerCursorName(at: 90, 30, images: images), "CROSS")
        t.equal(follower.map.pointerCursorName(at: 45, 15, images: images), nil, "MouseActionCursor=0 blocks what is behind")
        t.equal(follower.map.pointerCursorName(at: 55, 25, images: images), "TEXT", "behind: the meter's, from [Rainmeter]")

        // State bangs, hidden meters and a hidden container.
        for action in ["[!DisableMouseAction Disc LeftMouseUpAction]", "[!ClearMouseAction Caught *]",
                       "[!ToggleMouseAction Back LeftMouseDownAction]", "[!DisableMouseAction Rainmeter *]",
                       "[!HideMeter Disc]", "[!HideMeter Box]", "[!ShowMeter Disc][!Redraw]",
                       "[!SetOption Glassy MacGlass None][!UpdateMeter Glassy][!Redraw]",
                       "[!EnableMouseAction * *][!ShowMeter Box][!Redraw]",
                       "[!SetOption Disc ToolTipText \"New\"][!UpdateMeter Disc]",
                       "[!MoveMeter 0 0 Turned]"] {
            let before = skin.snapshotGeneration
            skin.execute(action, from: nil)
            t.check(skin.snapshotGeneration != before, "\(action) moves the generation")
            follower.refresh()
            t.equal(hitMapDifferences(skin, follower.map, hitMapPoints(skin, follower.map, grid: 30)), [], action)
        }
        // A piece of work that changes nothing the mouse finds leaves it.
        skin.update()
        follower.refresh()
        let rebuilds = follower.rebuilds
        skin.execute("[!SetVariable A 2]", from: nil)
        skin.update()
        follower.refresh()
        t.equal(follower.rebuilds, rebuilds, "nothing moved")
    }

    t.suite("Skin threading: hit map tooltips that show measures follow them") {
        let (skin, _) = try makeHitMapSkin(t, """
            [Rainmeter]
            Update=1000

            [MeasureCalc]
            Measure=Calc
            Formula=Counter

            [Tip]
            Meter=Image
            W=50
            H=50
            ToolTipText=Count %1
            MeasureName=MeasureCalc
            """)
        skin.update()
        var follower = HitMapFollower(skin)
        t.check(follower.map.toolTipsReadMeasures)
        let first = follower.map.toolTipInfo(at: 10, 10, images: skin.host as? SkinImageQueries)?.text
        t.equal(first, skin.toolTipInfo(at: 10, 10)?.text)
        skin.update()
        follower.refresh()
        t.check(follower.map.toolTipInfo(at: 10, 10, images: skin.host as? SkinImageQueries)?.text != first,
                "the next update's value")
        t.equal(hitMapDifferences(skin, follower.map, hitMapPoints(skin, follower.map)), [])
        skin.execute("[!UpdateMeasure MeasureCalc]", from: nil)
        follower.refresh()
        t.equal(hitMapDifferences(skin, follower.map, hitMapPoints(skin, follower.map)), [], "after a bang")
    }

    t.suite("Skin threading: hit map follows a Button's pixels and state") {
        let dir = t.temporaryDirectory("hitmap-button")
        let image = dir.appendingPathComponent("Strip.png")
        try writeTestPNG(image, width: 60, height: 20)
        let (skin, host) = try makeHitMapSkin(t, """
            [Rainmeter]
            Update=1000

            [Under]
            Meter=Image
            W=100
            H=40
            SolidColor=0,0,0,1
            LeftMouseUpAction=[!Log under]

            [Plain]
            Meter=Button
            X=10
            Y=10
            ButtonImage=\(image.path)
            ButtonCommand=[!Log plain]

            [Flipped]
            Meter=Button
            X=40
            Y=10
            ButtonImage=\(image.path)
            ImageFlip=Both
            LeftMouseDownAction=[!Log down]
            MouseActionCursorName=TEXT

            [Label]
            Meter=String
            X=10
            Y=10
            W=60
            H=20
            ToolTipText=Label
            """)
        skin.update()
        var follower = HitMapFollower(skin)
        t.check(follower.map.entries.contains { $0.isButton }, "Buttons are in the hit map")
        t.equal(hitMapDifferences(skin, follower.map, hitMapPoints(skin, follower.map, grid: 40)), [])
        // Pressed, then hovered: the frame on screen counts too.
        skin.mouseEvent(.leftDown, x: 16.5, y: 15.5)
        t.equal((skin.meter(named: "Plain") as? ButtonMeter)?.state, .pressed, "on an opaque pixel")
        follower.refresh()
        t.equal(hitMapDifferences(skin, follower.map, hitMapPoints(skin, follower.map, grid: 40)), [], "pressed")
        skin.mouseMoved(x: 46.5, y: 15.5)
        t.equal((skin.meter(named: "Flipped") as? ButtonMeter)?.state, .hover, "on an opaque pixel")
        follower.refresh()
        t.equal(hitMapDifferences(skin, follower.map, hitMapPoints(skin, follower.map, grid: 40)), [], "hovered")
        skin.mouseExited()
        follower.refresh()
        t.equal(hitMapDifferences(skin, follower.map, hitMapPoints(skin, follower.map, grid: 40)), [], "left")
        t.check(host.finishedWork > 0, "the host hears when work ends")
    }

    t.suite("Skin threading: hit map work ends once per outermost entry") {
        let (skin, host) = try makeHitMapSkin(t, """
            [Rainmeter]
            Update=1000
            OnUpdateAction=[!UpdateMeter *][!Redraw][!SetVariable A 1]

            [M]
            Meter=Image
            W=10
            H=10
            OnUpdateAction=[!UpdateMeasure C]
            LeftMouseUpAction=[!Update][!Redraw]

            [C]
            Measure=Calc
            Formula=1
            """)
        let afterLoad = host.finishedWork
        t.equal(afterLoad, 1, "the load is one piece of work")
        skin.update()
        t.equal(host.finishedWork, afterLoad + 1, "an update with nested actions and bangs is one")
        skin.mouseEvent(.leftUp, x: 5, y: 5)
        t.equal(host.finishedWork, afterLoad + 2, "a click whose action updates is one")
        let stable = skin.snapshotGeneration
        skin.update()
        t.equal(skin.snapshotGeneration, stable, "an update that changes nothing the mouse finds leaves the generation")
    }
}

/// A PNG of the given size (every pixel opaque red; `HitMapHost` makes a pattern of them transparent).
func writeTestPNG(_ url: URL, width: Int, height: Int) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Every test and default skin

func runHitMapCorpusTests(_ t: TestRunner) {
    t.suite("Skin threading: hit map matches every test and default skin") {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // Copies: the skins' own actions may write their files (`!WriteKeyValue`) or run scripts that do.
        let copies = t.temporaryDirectory("hitmap-corpus")
        var skinFiles: [(root: URL, config: String, file: URL)] = []
        for folder in ["TestSkins", "DefaultSkins"] {
            let copy = copies.appendingPathComponent(folder)
            try FileManager.default.copyItem(at: repo.appendingPathComponent(folder), to: copy)
            let files = FileManager.default.enumerator(at: copy, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "ini" } ?? []
            for file in files.sorted(by: { $0.path < $1.path }) {
                let relative = file.deletingLastPathComponent().path.dropFirst(copy.path.count + 1)
                guard !relative.isEmpty, !relative.contains("@") else { continue }
                skinFiles.append((copy, relative.replacingOccurrences(of: "/", with: "\\"), file))
            }
        }
        t.check(skinFiles.count > 100, "found the skins: \(skinFiles.count)")
        var checked = 0, withEntries = 0, buttons = 0, shapes = 0, glass = 0, containers = 0
        for (root, config, file) in skinFiles {
            let text = ((try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .utf16)) ?? "")
                .lowercased()
            // Skins that reach the network or start programs are left out; their meters are like the others'.
            if ["webparser", "ping", "runcommand"].contains(where: text.contains) { continue }
            let host = HitMapHost()
            let skin = Skin(config: config, fileURL: file, skinsDirectory: root, system: FakeSystem(), host: host)
            do { try skin.load() } catch { continue }
            defer { skin.close() }
            for _ in 0..<3 { skin.update() }
            var follower = HitMapFollower(skin)
            let name = file.path.dropFirst(root.deletingLastPathComponent().path.count + 1)
            checked += 1
            if !follower.map.entries.isEmpty { withEntries += 1 }
            if follower.map.entries.contains(where: \.isButton) { buttons += 1 }
            if follower.map.entries.contains(where: { if case .shapes = $0.shape { return true } else { return false } }) {
                shapes += 1
            }
            if follower.map.entries.contains(where: { $0.glass != nil }) { glass += 1 }
            if follower.map.entries.contains(where: { $0.container != nil }) { containers += 1 }
            t.equal(hitMapDifferences(skin, follower.map, hitMapPoints(skin, follower.map)), [], "\(name): after updates")

            // Mouse action state bangs on everything, then hiding the meters the mouse finds.
            let names = follower.map.entries.map(\.name)
            var disable = "[!DisableMouseAction * \"LeftMouseUpAction|LeftMouseDownAction|MouseOverAction\"]"
                + "[!DisableMouseAction Rainmeter *]"
            if let first = names.first { disable += "[!ClearMouseAction \"\(first)\" *]" }
            if names.count > 1 { disable += "[!ToggleMouseAction \"\(names[1])\" *]" }
            let steps = [disable, "[!EnableMouseAction * *][!EnableMouseAction Rainmeter *]",
                         names.prefix(3).map { "[!HideMeter \"\($0)\"]" }.joined(), "[!Redraw]",
                         "[!ShowMeter *][!Redraw]"]
            for step in steps {
                skin.execute(step, from: nil)
                follower.refresh()
                t.equal(hitMapDifferences(skin, follower.map, hitMapPoints(skin, follower.map, grid: 8, meters: 8),
                                          allKinds: false), [], "\(name): \(step)")
            }
            skin.update()
            follower.refresh()
            t.equal(hitMapDifferences(skin, follower.map, hitMapPoints(skin, follower.map, grid: 8, meters: 8),
                                      allKinds: false), [], "\(name): update")
        }
        print("    hit map: \(checked) skins, \(withEntries) with meters the mouse finds (\(buttons) with Buttons, "
              + "\(shapes) Shapes, \(glass) glass, \(containers) containers)")
        t.check(buttons > 0 && shapes > 0 && glass > 0 && containers > 0, "the corpus covers every kind of shape")
    }
}
