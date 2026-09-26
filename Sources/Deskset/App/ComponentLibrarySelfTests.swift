import AppKit
import DesksetCore

/// Self-tests of the editor's component library (`ComponentLibraryView`, `ComponentThumbnails`) and of dropping
/// components on the canvas (`SkinCanvasView`). Everything is headless: skins load with a `RenderHost` and sample
/// readings, views are never shown.
extension AppSelfTest {
    static func componentLibraryTests(_ t: AppTestRunner) {
        t.suite("App: library components load and draw") {
            // Every component, including the ones whose measures the app registers (NowPlaying, WiFiStatus).
            for c in EditorComponents.all {
                guard let loaded = ComponentThumbnails.loadSkin(c.id, x: 10, y: 20) else {
                    t.check(false, "\(c.id) loads")
                    continue
                }
                defer { loaded.close() }
                let skin = loaded.skin
                t.equal(skin.issues, [], c.id)
                t.equal(loaded.host.logs.filter { $0.contains("[Warning]") || $0.contains("[Error]") }, [], c.id)
                t.check(!skin.meters.isEmpty && skin.meters.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 },
                        "\(c.id) every meter has an area: \(skin.meters.map(\.frame))")
                guard let area = ComponentThumbnails.bounds(of: skin) else { t.check(false, "\(c.id) bounds"); continue }
                t.close(area.x, 10, "\(c.id) starts at its corner")
                t.close(area.y, 20, "\(c.id) starts at its corner")
                // The default size (the drop ghost) matches what is drawn: exactly for shapes and fixed sizes,
                // roughly for text (its width follows the value; the date's follows the day and month).
                let text = skin.meters.contains { $0 is StringMeter && $0.rawOption("W") == nil }
                let widthTolerance = c.id == "date" ? .infinity : text ? max(c.defaultSize.width * 0.3, 6) : 0.5
                t.close(area.width, c.defaultSize.width, accuracy: widthTolerance, "\(c.id) width")
                t.close(area.height, c.defaultSize.height, accuracy: text ? 3 : 0.5, "\(c.id) height")
            }
            // The app measures really run (they are not placeholders).
            if let loaded = ComponentThumbnails.loadSkin("nowplaying") {
                t.check(loaded.skin.measures.allSatisfy { $0 is NowPlayingMeasure }, "NowPlaying measures")
                t.equal((loaded.skin.meter(named: "MeterNowPlaying") as? StringMeter)?.text, "Not playing",
                        "an empty title reads Not playing")
                loaded.close()
            }
            if let loaded = ComponentThumbnails.loadSkin("wifi") {
                t.check(loaded.skin.measure(named: "MeasureWiFi") is WiFiStatusMeasure, "WiFiStatus measure")
                loaded.close()
            }
        }

        t.suite("App: library thumbnails") {
            ComponentThumbnails.clearCache()
            for dark in [true, false] {
                let backdrop = ComponentThumbnails.backdrop(dark: dark)
                for c in EditorComponents.all {
                    guard let image = ComponentThumbnails.thumbnail(for: c.id, dark: dark) else {
                        t.check(false, "\(c.id) thumbnail (dark \(dark))")
                        continue
                    }
                    t.check(image.size.width > 2 * ComponentThumbnails.padding && image.size.height > 2 * ComponentThumbnails.padding,
                            "\(c.id) thumbnail size \(image.size)")
                    t.check(inkPixels(image, backdrop: backdrop) >= 20, "\(c.id) thumbnail shows something (dark \(dark))")
                    t.check(ComponentThumbnails.thumbnail(for: c.id, dark: dark) === image, "\(c.id) cached")
                    t.check(ComponentThumbnails.isResolved(c.id, dark: dark))
                }
            }
            t.check(ComponentThumbnails.cachedThumbnail(for: "cpu", dark: true) !== ComponentThumbnails.cachedThumbnail(for: "cpu", dark: false),
                    "one per appearance")
            for c in EditorComponents.all {
                guard let preview = ComponentThumbnails.preview(for: c.id) else { t.check(false, "\(c.id) preview"); continue }
                t.check(inkPixels(preview, backdrop: nil) >= 20, "\(c.id) preview shows something")
            }
            let preview = ComponentThumbnails.preview(for: "cpu")
            t.equal(preview?.size, NSSize(width: 160, height: 6), "the preview is the component at its real size")
            t.check(ComponentThumbnails.dragImage(for: "cpu", dark: true) != nil, "drag image")
            t.equal(ComponentThumbnails.thumbnail(for: "no-such-component", dark: true)?.size,
                    ComponentThumbnails.thumbnail(for: "text", dark: true)?.size, "an unknown id is a Text")
        }

        t.suite("App: component library view") {
            var inserted: [String] = []
            let library = ComponentLibraryView(onInsert: { inserted.append($0) })
            library.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
            library.layoutSubtreeIfNeeded()
            t.equal(library.visibleIDs, EditorComponents.all.map(\.id), "everything, in library order")
            t.equal(library.columns, 2, "two columns in a 260-point sidebar")
            let cardWidth = library.card(for: "text")?.frame.width ?? 0
            t.check(cardWidth >= ComponentLibraryView.minCardWidth, "cards are at least the minimum width: \(cardWidth)")

            library.setFilter(query: "cpu", category: nil)
            t.equal(library.visibleIDs.first, "graph", "best match first")
            t.check(library.visibleIDs.contains("labelvalue"), "badge matches")
            t.equal(library.card(for: "clock")?.isHidden, true, "non-matching cards are hidden")
            t.equal(library.card(for: "graph")?.isHidden, false)
            t.equal(library.card(for: "graph")?.frame.origin, NSPoint(x: ComponentLibraryView.inset, y: 2),
                    "the best match takes the first cell")
            library.setFilter(query: "roundline", category: nil)
            t.equal(library.visibleIDs, ["gauge", "ring"], "Rainmeter names find components")
            library.setFilter(query: "", category: .shapes)
            t.equal(library.visibleIDs, ["rectangle", "circle", "divider"], "category chip")
            t.equal(library.category, .shapes)
            library.setFilter(query: "cpu", category: .gauges)
            t.equal(library.visibleIDs, ["gauge", "ring"], "search within a category")
            library.setFilter(query: "zzz", category: nil)
            t.equal(library.visibleIDs, [], "nothing matches")
            t.check(library.cards.allSatisfy(\.isHidden))

            // Return in the search field inserts the best match (quick insert); nothing to insert beeps.
            library.setFilter(query: "battery", category: nil)
            t.check(library.control(library.searchField, textView: NSTextView(),
                                    doCommandBy: #selector(NSResponder.insertNewline(_:))))
            t.equal(inserted, ["battery"])
            t.check(!library.control(library.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:))),
                    "other commands go to the field")

            // Clicking (or pressing) a card, Return or Space on a focused card.
            library.setFilter(query: "", category: nil)
            guard let clock = library.card(for: "clock") else { return t.check(false, "clock card") }
            _ = clock.accessibilityPerformPress()
            for keyCode: UInt16 in [36, 49] {
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                context: nil, characters: keyCode == 36 ? "\r" : " ",
                                                charactersIgnoringModifiers: keyCode == 36 ? "\r" : " ", isARepeat: false,
                                                keyCode: keyCode) {
                    clock.keyDown(with: event)
                }
            }
            t.equal(inserted, ["battery", "clock", "clock", "clock"])
            t.equal(clock.accessibilityLabel(), "Clock")
            t.equal(clock.accessibilityRole(), .button)

            // A drag carries the component id under the library's pasteboard type.
            t.equal(library.card(for: "cpu")?.pasteboardItem().string(forType: .desksetComponent), "cpu")
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.deskset.selftest.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            if let item = library.card(for: "cpu")?.pasteboardItem() { pasteboard.writeObjects([item]) }
            t.equal(SkinCanvasView.componentID(on: pasteboard), "cpu", "the canvas reads it back")
            pasteboard.clearContents()
            pasteboard.setString("no-such-component", forType: .desksetComponent)
            t.equal(SkinCanvasView.componentID(on: pasteboard), nil, "unknown ids are refused")

            // Narrow sidebar: one column. Thumbnails: every card gets one.
            library.frame.size.width = 200
            library.layoutSubtreeIfNeeded()
            t.equal(library.columns, 1)
            library.loadThumbnails()
            t.check(library.cards.allSatisfy { $0.thumbnail != nil }, "every card has a thumbnail")
            t.check(ComponentLibraryView.snapshot(query: nil, category: nil) != nil, "snapshot renders")
        }

        t.suite("App: canvas component drop") {
            // A 300×200 skin with a 40×40 box at (100, 50).
            let dir = t.temporaryDirectory("drop").appendingPathComponent("Skins/Drop", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("Drop.ini")
            try "[Rainmeter]\nSkinWidth=300\nSkinHeight=200\n[Box]\nMeter=Shape\nX=100\nY=50\nShape=Rectangle 0,0,40,40 | StrokeWidth 0\n"
                .write(to: file, atomically: true, encoding: .utf8)
            let host = RenderHost()
            let skin = Skin(config: "Drop", fileURL: file, skinsDirectory: dir.deletingLastPathComponent(),
                            system: ComponentSampleSystem(), host: host)
            try skin.load()
            skin.update()
            let canvas = SkinCanvasView(frame: .zero)
            canvas.skinProvider = { skin }
            canvas.updateSize()
            var drops: [(String, SkinRect)] = []
            canvas.onDropComponent = { drops.append(($0, $1)) }
            let m = SkinCanvasView.margin
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x + m, y: y + m) }
            func guides() -> [String] { canvas.guides.map { "\($0.axis) \(SkinCanvasView.format($0.position))" } }

            // Centred on the pointer; its centre line snaps to the skin's centre (150).
            let bar = canvas.componentDragMoved(id: "cpu", to: point(151, 120))
            t.equal(bar, SkinRect(x: 70, y: 117, width: 160, height: 6))
            t.equal(canvas.componentGhost?.id, "cpu", "the ghost follows the pointer")
            t.equal(guides(), ["vertical 150"], "and shows the guide")
            // Snapping to the box's right edge and the skin's middle, like a moved meter.
            let circle = canvas.componentDragMoved(id: "circle", to: point(147, 76))
            t.equal(circle, SkinRect(x: 120, y: 52, width: 48, height: 48))
            t.equal(guides(), ["vertical 120", "horizontal 100"])
            // ⌘ turns snapping off: the pointer position as is, rounded to whole points.
            t.equal(canvas.componentDragMoved(id: "circle", to: point(147.4, 76.6), snapping: false),
                    SkinRect(x: 123, y: 53, width: 48, height: 48))
            t.equal(guides(), [])
            // Never above or left of the skin's origin.
            t.equal(canvas.componentDragMoved(id: "rectangle", to: point(10, 10)), SkinRect(x: 0, y: 0, width: 120, height: 48))

            // The ghost is drawn (preview, fill, outline): the canvas looks different there.
            canvas.componentDragMoved(id: "circle", to: point(220, 150), snapping: false)
            let withGhost = render(canvas)
            canvas.componentDragEnded()
            t.check(canvas.componentGhost == nil && canvas.guides.isEmpty, "leaving the canvas clears the ghost")
            let without = render(canvas)
            let probe = NSPoint(x: 220 + m, y: 150 + m)
            t.check(pixel(withGhost, at: probe) != pixel(without, at: probe), "ghost drawn at the pointer")

            // The drop reports the ghost's frame and clears it.
            t.check(canvas.dropComponent(id: "cpu", at: point(151, 120)))
            t.equal(drops.count, 1)
            t.equal(drops.first?.0, "cpu")
            t.equal(drops.first?.1, SkinRect(x: 70, y: 117, width: 160, height: 6))
            t.check(canvas.componentGhost == nil && canvas.guides.isEmpty)
            // Refused: unknown components, and while the canvas is not editable.
            t.check(!canvas.dropComponent(id: "no-such-component", at: point(10, 10)))
            canvas.isEditable = false
            t.check(!canvas.dropComponent(id: "cpu", at: point(10, 10)))
            t.equal(canvas.componentDragMoved(id: "cpu", to: point(10, 10)), nil)
            t.equal(drops.count, 1, "nothing else dropped")
            canvas.isEditable = true

            // The same through AppKit's drag-destination calls, with a stub drag: the ghost replaces the drag's own
            // image over the canvas, and the image comes back whenever the ghost goes away without a drop.
            drops = []
            let dragBoard = NSPasteboard(name: NSPasteboard.Name("com.deskset.selftest.\(UUID().uuidString)"))
            defer { dragBoard.releaseGlobally() }
            let drag = StubDraggingInfo(pasteboard: dragBoard, component: "cpu", sequence: 1)
            let item = drag.items[0]
            func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { canvas.convert(point(x, y), to: nil) }
            // Read through the provider: `imageComponents` caches its first answer outside a real session.
            func components(_ item: NSDraggingItem) -> [NSDraggingImageComponent] { item.imageComponentsProvider?() ?? [] }
            func imageHidden() -> Bool { components(item).isEmpty }
            /// The drag shows an image centred on skin point (x, y).
            func imageShown(centredOn x: CGFloat, _ y: CGFloat) -> Bool {
                guard let first = components(item).first, first.contents is NSImage else { return false }
                return abs(item.draggingFrame.midX - point(x, y).x) < 0.5 && abs(item.draggingFrame.midY - point(x, y).y) < 0.5
            }
            t.check(!imageHidden(), "the drag starts with the card's thumbnail")
            drag.draggingLocation = at(151, 120)
            t.equal(canvas.draggingEntered(drag), .copy)
            t.equal(canvas.componentGhost?.frame, SkinRect(x: 70, y: 117, width: 160, height: 6), "entered: ghost")
            t.check(imageHidden(), "entered: the ghost stands in for the drag image")
            drag.draggingLocation = at(147, 76)
            t.equal(canvas.draggingUpdated(drag), .copy)
            t.check(imageHidden(), "moved: still hidden")
            // The canvas stops taking drops while the pointer is on it: refused, image back.
            canvas.isEditable = false
            t.equal(canvas.draggingUpdated(drag), [])
            t.check(canvas.componentGhost == nil, "refused: no ghost")
            t.check(imageShown(centredOn: 147, 76), "refused: the thumbnail is back, centred on the pointer")
            canvas.isEditable = true
            drag.draggingLocation = at(200, 100)
            t.equal(canvas.draggingUpdated(drag), .copy)
            t.check(canvas.componentGhost != nil && imageHidden(), "taken again: ghost, no image")
            // Leaving the canvas (or cancelling over it): no ghost, image back for the rest of the drag / the slide.
            drag.draggingLocation = at(290, 190)
            canvas.draggingExited(drag)
            t.check(canvas.componentGhost == nil && canvas.guides.isEmpty, "exited: no ghost")
            t.check(imageShown(centredOn: 290, 190), "exited: the thumbnail is back")
            // Back in and dropped: the drop reports the snapped frame.
            drag.draggingLocation = at(151, 120)
            t.equal(canvas.draggingEntered(drag), .copy)
            t.check(imageHidden())
            t.check(canvas.performDragOperation(drag), "dropped")
            canvas.concludeDragOperation(drag)
            t.equal(drops.count, 1)
            t.equal(drops.first?.0, "cpu")
            t.equal(drops.first?.1, SkinRect(x: 70, y: 117, width: 160, height: 6))
            t.check(canvas.componentGhost == nil)
            // A failed drop (the canvas stopped being editable just before): refused, and the image that slides
            // back to the card is the thumbnail again.
            let failing = StubDraggingInfo(pasteboard: dragBoard, component: "circle", sequence: 2)
            failing.draggingLocation = at(220, 150)
            t.equal(canvas.draggingEntered(failing), .copy)
            t.check(components(failing.items[0]).isEmpty, "second drag: hidden (fresh per drag)")
            canvas.isEditable = false
            t.check(!canvas.performDragOperation(failing), "drop refused")
            t.check(components(failing.items[0]).first?.contents is NSImage, "failed drop: the thumbnail is back")
            t.equal(drops.count, 1, "nothing else dropped")
            canvas.isEditable = true
            // Something else on the pasteboard: not a component drag, nothing changes.
            dragBoard.clearContents()
            dragBoard.setString("hello", forType: .string)
            let other = StubDraggingInfo(pasteboard: dragBoard, component: nil, sequence: 3)
            other.draggingLocation = at(151, 120)
            t.equal(canvas.draggingEntered(other), [])
            t.check(canvas.componentGhost == nil)

            // At 400% the snap distance is 5 screen points = 1.25 skin points.
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            scroll.allowsMagnification = true
            scroll.maxMagnification = SkinCanvasView.maxZoom
            scroll.minMagnification = SkinCanvasView.minZoom
            scroll.documentView = canvas
            canvas.setZoom(4)
            t.equal(canvas.componentDragMoved(id: "circle", to: point(147, 76))?.x, 123, "3 points is too far at 400%")
            t.equal(canvas.componentDragMoved(id: "circle", to: point(145, 76))?.x, 120, "1 point snaps")
            canvas.componentDragEnded()
            withExtendedLifetime(host) {}
            skin.close()
        }
    }

    /// Pixels of `image` that differ clearly from `backdrop` (nil: that are not transparent).
    static func inkPixels(_ image: NSImage, backdrop: NSColor?) -> Int {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let rep = NSBitmapImageRep(cgImage: cg)
        let reference = backdrop?.usingColorSpace(.deviceRGB)
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if let reference {
                    let d = max(abs(c.redComponent - reference.redComponent), abs(c.greenComponent - reference.greenComponent),
                                abs(c.blueComponent - reference.blueComponent))
                    if d > 12.0 / 255 { count += 1 }
                } else if c.alphaComponent > 0.05 {
                    count += 1
                }
            }
        }
        return count
    }

    /// The view drawn into a 1x bitmap.
    private static func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The color at a point in view coordinates (flipped view) of a `render` result.
    private static func pixel(_ rep: NSBitmapImageRep?, at p: NSPoint) -> NSColor? {
        guard let rep else { return nil }
        let sx = CGFloat(rep.pixelsWide) / rep.size.width, sy = CGFloat(rep.pixelsHigh) / rep.size.height
        return rep.colorAt(x: Int(p.x * sx), y: Int(p.y * sy))
    }
}

/// A drag in progress as a drop target sees it, without a real dragging session: one item carrying `component` (nil:
/// whatever is already on the pasteboard) that starts with a drag image, like the library card's. Changes the
/// destination makes to the item stay on it, so tests can see them.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSequenceNumber: Int
    let items: [NSDraggingItem]
    var draggingLocation: NSPoint = .zero
    var draggingSourceOperationMask: NSDragOperation = [.copy, .generic]
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(pasteboard: NSPasteboard, component: String?, sequence: Int) {
        draggingPasteboard = pasteboard
        draggingSequenceNumber = sequence
        let writer = NSPasteboardItem()
        if let component {
            writer.setString(component, forType: .desksetComponent)
            pasteboard.clearContents()
            pasteboard.setString(component, forType: .desksetComponent)
        }
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(size: NSSize(width: 40, height: 30))
        item.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
        items = [item]
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        for (index, item) in items.enumerated() {
            block(item, index, &stop)
            if stop.boolValue { break }
        }
    }
}
