import Foundation

// Where the mouse finds a skin's meters, as plain values (docs/skin-threading.md §5.5, phase 2 step 2). The engine's own
// mouse lookups (`Meter.isHit`, `ShapeMeter.hitTest`, `ButtonMeter.hitTest`) test the same values, through the same
// code, as the app's window does with a skin's snapshot (`SkinHitMap`): there is one hit test, not two that could drift
// apart. A skin that runs on a thread of its own publishes its hit map after each piece of work, and the main thread
// answers AppKit's questions from it (can this press drag the window, which cursor goes here, which tooltip) without
// waiting for the skin.

// MARK: - Mouse shapes

/// The area where the mouse finds one meter (`Meter.hitTest`), as a value: it can be kept, compared and tested on any
/// thread.
public enum MouseShape: Equatable, Sendable {
    /// Found nowhere: a hidden Shape meter, a Shape turned by a matrix that cannot be undone, a Button without an image.
    case nowhere
    /// The frame (most meters).
    case rect(SkinRect)
    /// A Shape meter's solid parts (and its background when it has one).
    case shapes(ShapeMouseShape)
    /// A Button meter's image: its opaque pixels.
    case button(ButtonMouseShape)

    /// Whether the point (skin coordinates) is in the area. `images` answers a Button's pixels (nil: every pixel is
    /// opaque); it is asked only for a Button.
    public func contains(x: Double, y: Double, images: @autoclosure () -> SkinImageQueries?) -> Bool {
        switch self {
        case .nowhere: return false
        case .rect(let r): return r.contains(x: x, y: y)
        case .shapes(let s): return s.contains(x: x, y: y)
        case .button(let b): return b.contains(x: x, y: y, images: images())
        }
    }
}

/// A Shape meter's mouse area (manual: Shape → Mouse Detection on Shapes): any solid part of its shapes, even outside
/// the frame, or its own SolidColor background; its TransformationMatrix moves both.
public struct ShapeMouseShape: Equatable, Sendable {
    /// The meter's frame (skin coordinates): where the background is.
    public var frame: SkinRect
    /// Where the shapes start: the frame's corner after Padding.
    public var originX: Double
    public var originY: Double
    /// The inverse of the meter's TransformationMatrix (nil: none).
    public var inverse: ShapeTransform?
    /// SolidColor or SolidColor2 is not fully transparent.
    public var solidBackground: Bool
    /// The shapes, in drawing order, and their flattened geometry (built once per change of the shapes).
    public var items: [ShapeItem]
    var regions: [ShapeHitTester.FlatRegion]

    init(frame: SkinRect, originX: Double, originY: Double, inverse: ShapeTransform?, solidBackground: Bool,
         items: [ShapeItem], regions: [ShapeHitTester.FlatRegion]) {
        self.frame = frame
        self.originX = originX
        self.originY = originY
        self.inverse = inverse
        self.solidBackground = solidBackground
        self.items = items
        self.regions = regions
    }

    func contains(x: Double, y: Double) -> Bool {
        var p = ShapePoint(x, y)
        if let inverse { p = inverse.apply(p) }
        if solidBackground && frame.contains(x: p.x, y: p.y) { return true }
        let local = ShapePoint(p.x - originX, p.y - originY)
        return zip(items, regions).contains { ShapeHitTester.hit($0.0, local, region: $0.1) }
    }

    /// The regions follow from the items.
    public static func == (a: ShapeMouseShape, b: ShapeMouseShape) -> Bool {
        a.frame == b.frame && a.originX == b.originX && a.originY == b.originY && a.inverse == b.inverse
            && a.solidBackground == b.solidBackground && a.items == b.items
    }
}

/// A Button meter's mouse area: the non-transparent pixels of the normal frame of its image, or of the frame on screen
/// (see `ButtonMeter.hitTest`, which says why both).
public struct ButtonMouseShape: Equatable, Sendable {
    /// The image file (or `sf:` symbol).
    public var path: String
    /// Where the frame is drawn (skin coordinates, one frame big).
    public var destination: SkinRect
    /// One frame's size in image pixels.
    public var frameWidth: Double
    public var frameHeight: Double
    /// ImageFlip, applied to every frame in place.
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    /// The normal frame's place in the image (pixels).
    public var normalSource: SkinRect
    /// The place of the frame on screen when it is not the normal one (pressed, hover).
    public var shownSource: SkinRect?
    /// The pixels are read after the image's EXIF orientation.
    public var exifOriented: Bool

    func contains(x: Double, y: Double, images: SkinImageQueries?) -> Bool {
        guard destination.contains(x: x, y: y) else { return false }
        var lx = (x - destination.x).rounded(.down), ly = (y - destination.y).rounded(.down)
        if flipHorizontal { lx = frameWidth - 1 - lx }
        if flipVertical { ly = frameHeight - 1 - ly }
        func opaque(_ source: SkinRect) -> Bool {
            let px = Int((source.x + lx).clamped(0, ImageOptions.maxSide))
            let py = Int((source.y + ly).clamped(0, ImageOptions.maxSide))
            // Unknown (no image queries, or the host cannot read the pixel): opaque.
            guard let alpha = images?.imagePixelAlpha(atPath: path, x: px, y: py, exifOriented: exifOriented)
            else { return true }
            return alpha > 0
        }
        return opaque(normalSource) || (shownSource.map(opaque) ?? false)
    }
}

/// The rule of `Meter.isHit` on values, shared by the live meters and the hit map.
enum MouseHit {
    /// A visible meter is hit at the point when its glass is there (except for a Button's own reaction, `precise` on a
    /// meter that handles the mouse itself), or its area is (`shape` when `precise`, else the frame) — and, for content
    /// of a container, the container's area is there too (`container`: its `hitTest` shape, `.nowhere` while it is
    /// hidden; nil when the meter is not content).
    @inline(__always)
    static func isHit(x: Double, y: Double, precise: Bool, handlesMouseItself: Bool, glass: GlassRegion?,
                      frame: SkinRect, shape: () -> MouseShape, container: () -> MouseShape?,
                      images: @autoclosure () -> SkinImageQueries?) -> Bool {
        if !(precise && handlesMouseItself), let glass, glass.contains(x: x, y: y) { return true }
        guard precise ? shape().contains(x: x, y: y, images: images()) : frame.contains(x: x, y: y) else { return false }
        if let area = container() { return area.contains(x: x, y: y, images: images()) }
        return true
    }
}

// MARK: - The hit map

/// Everything a skin's window asks about the mouse, as of the skin's last piece of work (docs/skin-threading.md §5.5):
/// the meters the mouse can find with what they do there, the `[Rainmeter]` section's mouse actions and cursor, the
/// tooltips, the drag margins and the skin's size. Its answers are the live skin's (`Skin.hasAction`,
/// `Skin.mouseCursorName`, `Skin.toolTipInfo`, `Skin.isInDragArea`, `Skin.isOnButton`): the same rules, on the values
/// they read. Built on the skin's owner (`Skin.makeHitMap()`); read anywhere. Image queries are supplied when asking
/// a question, so the map keeps no reference to a skin, its host or an image service.
public struct SkinHitMap: Equatable, Sendable {
    /// What one mouse action does at a meter or the skin: none (not defined or cleared: the event goes on to what is
    /// behind), caught (disabled, or only empty brackets like `[]`: the event stops there and nothing runs) or runs.
    public enum Action: UInt8, Sendable {
        case absent, caught, runs
    }

    /// One meter the mouse can find: it has a mouse action, a tooltip or `MouseActionCursor=0`, or is a Button. Hidden
    /// meters are left out (the mouse never finds them). Immutable, so it can be read on any thread; a class, so the
    /// lookups that walk the entries on every mouse move do not copy them.
    public final class Entry: Equatable, Sendable {
        public let name: String
        /// Shared-program occurrence identity. Legacy meter lookups keep their original name and nil default.
        public let elementID: ElementID?
        public let frame: SkinRect
        /// `Meter.hitTest`'s area.
        public let shape: MouseShape
        /// The container's `hitTest` area (`.nowhere` while it is hidden); nil when the meter is not content.
        public let container: MouseShape?
        /// The glass shown behind the meter (`Skin.shownGlassRegion`).
        public let glass: GlassRegion?
        /// A Button: it reacts to the mouse itself (`Meter.handlesMouseItself`).
        public let isButton: Bool
        /// The mouse actions that are not `.absent`.
        public let actions: [MouseEventKind: Action]
        /// `MouseActionCursor` and `MouseActionCursorName`.
        public let cursor: Bool
        public let cursorName: String
        /// The tooltip with `%1`, `%2`… as they were (nil: none shown).
        public let toolTip: ToolTipInfo?

        public init(name: String, frame: SkinRect, shape: MouseShape, container: MouseShape?, glass: GlassRegion?,
                    isButton: Bool, actions: [MouseEventKind: Action], cursor: Bool, cursorName: String,
                    toolTip: ToolTipInfo?, elementID: ElementID? = nil) {
            self.name = name
            self.elementID = elementID
            self.frame = frame
            self.shape = shape
            self.container = container
            self.glass = glass
            self.isButton = isButton
            self.actions = actions
            self.cursor = cursor
            self.cursorName = cursorName
            self.toolTip = toolTip
        }

        public func action(_ kind: MouseEventKind) -> Action { actions[kind] ?? .absent }

        public static func == (a: Entry, b: Entry) -> Bool {
            a === b || (a.name == b.name && a.frame == b.frame && a.shape == b.shape && a.container == b.container
                        && a.glass == b.glass && a.isButton == b.isButton && a.actions == b.actions
                        && a.cursor == b.cursor && a.cursorName == b.cursorName && a.toolTip == b.toolTip
                        && a.elementID == b.elementID)
        }
    }

    /// Top first: the reverse of file order, the order the engine tries meters in.
    public var entries: [Entry] = []
    /// The `[Rainmeter]` section's mouse actions that are not `.absent`.
    public var skinActions: [MouseEventKind: Action] = [:]
    /// `[Rainmeter]` `MouseActionCursor` / `MouseActionCursorName`.
    public var skinCursor = true
    public var skinCursorName = ""
    /// `ToolTipHidden=1` in `[Rainmeter]`.
    public var toolTipHidden = false
    /// The skin's size (points) and `DragMargins`.
    public var width = 0.0
    public var height = 0.0
    public var dragMargins = SkinInsets.zero
    /// One area per meter that shows a tooltip, in file order, at most `maxToolTipAreas` (`toolTipAreas(of:)`).
    public var toolTipAreas: [SkinRect] = []
    /// Some tooltip shows measure values (`%1`…): it changes with them.
    public var toolTipsReadMeasures = false
    /// Most tooltip areas one skin registers with its window.
    public static let maxToolTipAreas = 512

    public init() {}

    public func skinAction(_ kind: MouseEventKind) -> Action { skinActions[kind] ?? .absent }

    // MARK: Answers

    /// `Meter.isHit(x:y:precise:)` of the entry's meter. `images` answers Button pixels, including those of a
    /// container; nil keeps the engine's fallback that unknown pixels are opaque.
    public func isHit(_ e: Entry, x: Double, y: Double, precise: Bool, images: SkinImageQueries?) -> Bool {
        MouseHit.isHit(x: x, y: y, precise: precise, handlesMouseItself: e.isButton, glass: e.glass, frame: e.frame,
                       shape: { e.shape }, container: { e.container }, images: images)
    }

    /// `Meter.isHit(x:y:)`: a Button's mouse actions use its frame, other meters their area.
    public func isHit(_ e: Entry, x: Double, y: Double, images: SkinImageQueries?) -> Bool {
        isHit(e, x: x, y: y, precise: !e.isButton, images: images)
    }

    /// `Skin.meter(at:_:handling:)`: the topmost meter hit at the point that does something for `kind`.
    public func entry(at x: Double, _ y: Double, handling kind: MouseEventKind, images: SkinImageQueries?) -> Entry? {
        entries.first { $0.action(kind) != .absent && isHit($0, x: x, y: y, images: images) }
    }

    /// `Skin.hasAction`: a click there runs (or is caught by) an action.
    public func hasAction(_ kind: MouseEventKind, x: Double, y: Double, images: SkinImageQueries?) -> Bool {
        entry(at: x, y, handling: kind, images: images) != nil || skinAction(kind) != .absent
    }

    /// What `Skin.mouseEvent(kind…)` answers — whether an action ran or caught the event, or a Button took it — for an
    /// event that is not the release of a press a Button holds (the engine gives that release to the Button first).
    public func handles(_ kind: MouseEventKind, x: Double, y: Double, images: SkinImageQueries?) -> Bool {
        for e in entries where isHit(e, x: x, y: y, images: images) {
            // A Button takes a press on its pixels itself, or leaves it to its own action: handled either way.
            if e.isButton && kind == .leftDown && e.shape.contains(x: x, y: y, images: images) { return true }
            if e.action(kind) != .absent { return true }
        }
        return skinAction(kind) != .absent
    }

    /// The topmost Button there (its frame or glass), the one the engine gives a click first.
    public func topButton(at x: Double, _ y: Double, images: SkinImageQueries?) -> Entry? {
        entries.first { $0.isButton && isHit($0, x: x, y: y, images: images) }
    }

    /// `Skin.isOnButton`: the point is on the image of the topmost Button there.
    public func isOnButton(x: Double, y: Double, images: SkinImageQueries?) -> Bool {
        guard let button = topButton(at: x, y, images: images) else { return false }
        return button.shape.contains(x: x, y: y, images: images)
    }

    /// `Skin.mouseCursorName`: the cursor the mouse actions ask for there.
    public func mouseCursorName(at x: Double, _ y: Double, images: SkinImageQueries?) -> String? {
        for e in entries where isHit(e, x: x, y: y, images: images) {
            if !e.cursor { return nil }
            switch Skin.cursorTarget(e.action) {
            case .pointer: return e.cursorName.isEmpty ? "HAND" : e.cursorName
            case .blocked: return nil
            case .nothing: continue
            }
        }
        if skinCursor, Skin.cursorTarget(skinAction) == .pointer {
            return skinCursorName.isEmpty ? "HAND" : skinCursorName
        }
        return nil
    }

    /// `Skin.pointerCursorName`: over a Button's image the pointer of that Button, else the mouse actions' cursor.
    public func pointerCursorName(at x: Double, _ y: Double, images: SkinImageQueries?) -> String? {
        if let button = topButton(at: x, y, images: images), button.shape.contains(x: x, y: y, images: images) {
            guard button.cursor else { return nil }
            return button.cursorName.isEmpty ? "HAND" : button.cursorName
        }
        return mouseCursorName(at: x, y, images: images)
    }

    /// `Skin.toolTipInfo(at:)`: the tooltip of the topmost meter there that has one.
    public func toolTipInfo(at x: Double, _ y: Double, images: SkinImageQueries?) -> ToolTipInfo? {
        guard !toolTipHidden else { return nil }
        for e in entries where isHit(e, x: x, y: y, images: images) {
            if let tip = e.toolTip { return tip }
        }
        return nil
    }

    /// `Skin.isInDragArea`: outside the drag margins.
    public func isInDragArea(x: Double, y: Double) -> Bool {
        Skin.isInDragArea(x: x, y: y, margins: dragMargins, width: width, height: height)
    }

    /// The map's values, independent of the image service used to query them.
    public static func == (a: SkinHitMap, b: SkinHitMap) -> Bool {
        a.entries == b.entries && a.skinActions == b.skinActions && a.skinCursor == b.skinCursor
            && a.skinCursorName == b.skinCursorName && a.toolTipHidden == b.toolTipHidden && a.width == b.width
            && a.height == b.height && a.dragMargins == b.dragMargins && a.toolTipAreas == b.toolTipAreas
            && a.toolTipsReadMeasures == b.toolTipsReadMeasures
    }
}

// MARK: - Building it

extension SkinHitMap.Action {
    /// A mouse action as the engine sees it (`effectiveMouseAction`): nil when not defined or cleared, `""` when
    /// disabled.
    init(_ effective: String?) {
        guard let effective else {
            self = .absent
            return
        }
        self = Skin.isEmptyAction(effective) ? .caught : .runs
    }
}

extension Skin {
    /// What the mouse finds in the skin now (see `SkinHitMap`). On the skin's owner.
    public func makeHitMap() -> SkinHitMap {
        assertOwned()
        var map = SkinHitMap()
        map.width = width
        map.height = height
        map.dragMargins = settings.dragMargins
        map.toolTipHidden = settings.toolTipHidden
        map.skinCursor = settings.mouseActionCursor
        map.skinCursorName = settings.mouseActionCursorName
        if let root = rainmeterSection {
            for kind in root.mouseActions.keys {
                let action = SkinHitMap.Action(root.effectiveMouseAction(kind))
                if action != .absent { map.skinActions[kind] = action }
            }
        }
        var readsMeasures = false
        for m in meters.reversed() where !m.hidden {
            var actions: [MouseEventKind: SkinHitMap.Action] = [:]
            for kind in m.mouseActions.keys {
                let action = SkinHitMap.Action(m.effectiveMouseAction(kind))
                if action != .absent { actions[kind] = action }
            }
            let toolTip = m.toolTipInfo
            guard m.handlesMouseItself || !actions.isEmpty || !m.mouseActionCursor || toolTip != nil else { continue }
            if toolTip != nil && m.toolTipReadsMeasures { readsMeasures = true }
            map.entries.append(SkinHitMap.Entry(
                name: m.name, frame: m.frame, shape: m.mouseShape,
                container: m.container.map { $0.hidden ? .nowhere : $0.mouseShape },
                glass: shownGlassRegion(of: m), isButton: m.handlesMouseItself, actions: actions,
                cursor: m.mouseActionCursor, cursorName: m.mouseActionCursorName, toolTip: toolTip))
        }
        map.toolTipAreas = toolTipAreas()
        map.toolTipsReadMeasures = readsMeasures
        hitMapReadsMeasures = readsMeasures
        return map
    }

    /// The tooltip areas (skin coordinates): one per meter that shows a tooltip, in file order, at most
    /// `SkinHitMap.maxToolTipAreas`. A meter's area is its frame, cut off at its container's, plus its glass
    /// (`MacGlass`), which is part of the meter for the mouse (`Meter.isOnGlass`) also where it lies outside the frame:
    /// moved by a TransformationMatrix, or a Shape's Rectangle beyond it. None while `[Rainmeter]` hides tooltips.
    public func toolTipAreas() -> [SkinRect] {
        var areas: [SkinRect] = []
        guard !settings.toolTipHidden else { return areas }
        for m in meters where !m.hidden && !m.toolTipHidden && !m.toolTipText.isEmpty {
            var r: SkinRect? = m.frame
            if let container = m.container {
                // Content of a hidden container "in effect doesn't exist" (no tooltip either).
                guard !container.hidden else { continue }
                r = m.frame.intersection(container.frame)
            }
            if let glass = shownGlassRegion(of: m) {
                // Already cut off at the container's frame (`clip`), as shown.
                let area = glass.clip.map { glass.rect.intersection($0) } ?? glass.rect
                if let area, area.width > 0, area.height > 0 {
                    if let current = r, current.width > 0, current.height > 0 {
                        r = current.union(area)
                    } else {
                        r = area
                    }
                }
            }
            guard let r, r.width > 0, r.height > 0, r.x.isFinite, r.y.isFinite else { continue }
            areas.append(r)
            if areas.count >= SkinHitMap.maxToolTipAreas { break }
        }
        return areas
    }

    /// Whether the point is on the image of the topmost Button meter there (transparent pixels are not the button), like
    /// the engine's dispatch of clicks (Buttons first, even under other meters): such a press never drags the window.
    public func isOnButton(x: Double, y: Double) -> Bool {
        assertOwned()
        guard let button = meters.last(where: { $0.handlesMouseItself && $0.isHit(x: x, y: y) }) as? ButtonMeter
        else { return false }
        return button.hitTest(x: x, y: y)
    }

    /// The cursor at a skin point: the pointer over the image of a Button meter (the button that a click there
    /// presses: the engine gives Buttons the clicks before other meters, so a label drawn over a button does not hide
    /// it), otherwise the mouse actions' choice (`mouseCursorName`).
    public func pointerCursorName(x: Double, y: Double) -> String? {
        assertOwned()
        if let button = meters.last(where: { $0.handlesMouseItself && $0.isHit(x: x, y: y) }) as? ButtonMeter,
           button.hitTest(x: x, y: y) {
            guard button.mouseActionCursor else { return nil }
            return button.mouseActionCursorName.isEmpty ? "HAND" : button.mouseActionCursorName
        }
        return mouseCursorName(at: x, y)
    }
}

extension SkinRect {
    /// The overlap with `other`; nil when they do not overlap (touching edges give an empty rectangle, as CGRect's).
    public func intersection(_ other: SkinRect) -> SkinRect? {
        let left = max(x, other.x), top = max(y, other.y)
        let right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
        guard right >= left, bottom >= top else { return nil }
        return SkinRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The smallest rectangle holding both.
    public func union(_ other: SkinRect) -> SkinRect {
        let left = min(x, other.x), top = min(y, other.y)
        return SkinRect(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
    }
}
