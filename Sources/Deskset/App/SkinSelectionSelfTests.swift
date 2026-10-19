import AppKit
import DesksetCore

/// Synthetic selection input over headless windows. Fixtures and state files stay inside the test directory.
enum SkinSelectionSelfTests {
    static func run(_ t: AppTestRunner) {
        edgeTests(t)
        groupTests(t)
        persistenceTests(t)
        layoutCaptureTests(t)
        zoomDragTests(t)
        cornerTests(t)
        multiSelectionTests(t)
        inputTests(t)
        menuTrackingTests(t)
        forceTests(t)
    }

    private struct Fixture {
        let app: AppController
        let a: SkinWindowController
        let b: SkinWindowController
        let c: SkinWindowController
        let d: SkinWindowController
        var all: [SkinWindowController] { [a, b, c, d] }
    }

    private static func load(_ t: AppTestRunner) throws -> Fixture? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        for (index, entry) in [("A", "Alpha"), ("B", "alpha"), ("C", "Beta"), ("D", "Other")].enumerated() {
            let (name, group) = entry
            let config = "Selection\\" + name
            let folder = app.skinsDirectory.appendingPathComponent("Selection/" + name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
            [Rainmeter]
            Update=-1
            DragGroup=\(group)
            [Face]
            Meter=Image
            W=100
            H=80
            SolidColor=40,90,150,255
            """.write(to: folder.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
            app.state.update(config) {
                $0.file = "Skin.ini"
                $0.x = Double(200 + 120 * index)
                $0.y = 200
                $0.keepOnScreen = false
                $0.snapEdges = false
                if name == "A" { $0.dragGroup = "beta" }
            }
        }
        app.rescanLibrary()
        guard let a = app.activate(config: "Selection\\A", file: nil),
              let b = app.activate(config: "Selection\\B", file: nil),
              let c = app.activate(config: "Selection\\C", file: nil),
              let d = app.activate(config: "Selection\\D", file: nil) else {
            t.check(false, "all selection fixtures load")
            return nil
        }
        let fixture = Fixture(app: app, a: a, b: b, c: c, d: d)
        t.check(AppSelfTest.spin { fixture.all.allSatisfy(\.isStarted) }, "fixtures started")
        t.atSuiteEnd {
            app.skinSelection.clear()
            app.stopAllForTermination()
        }
        return fixture
    }

    private static func edgeTests(_ t: AppTestRunner) {
        t.suite("App: skin selection: edge targets use ten physical pixels and L-shaped corners") {
            for scale: CGFloat in [1, 2] {
                let size = NSSize(width: 100 / scale, height: 80 / scale)
                func edge(_ x: CGFloat, _ y: CGFloat) -> SkinSelectionController.Edge {
                    SkinSelectionController.edge(at: NSPoint(x: x / scale, y: y / scale),
                                                 size: size, backingScale: scale)
                }
                t.equal(edge(9.5, 40), .left)
                t.equal(edge(10, 40), [], "the eleventh physical pixel is interior")
                t.equal(edge(90, 40), .right)
                t.equal(edge(89, 40), [])
                t.equal(edge(50, 9.5), .top)
                t.equal(edge(50, 10), [])
                t.equal(edge(50, 70), .bottom)
                t.equal(edge(50, 69), [])
                t.equal(edge(5, 19), [.left, .top], "the vertical arm of the corner")
                t.equal(edge(19, 5), [.left, .top], "the horizontal arm of the corner")
                t.equal(edge(15, 15), [], "the corner does not fill a twenty-pixel square")
                t.equal(edge(20, 5), .top)
                t.equal(edge(99, 79), [.right, .bottom])
                t.equal(edge(-1, 20), [])
                t.equal(edge(100, 20), [], "the outer rectangle excludes its far edge")
                let tiny = NSSize(width: 6 / scale, height: 4 / scale)
                t.equal(SkinSelectionController.edge(at: .zero, size: tiny, backingScale: scale), [.left, .top])
                t.equal(SkinSelectionController.edge(at: NSPoint(x: 5 / scale, y: 3 / scale),
                                                     size: tiny, backingScale: scale), [.right, .bottom])
            }
            t.equal(SkinSelectionController.edge(at: .zero, size: .zero, backingScale: 2), [])
            t.check(SkinSelectionController.isSelectionGesture([.control, .option]))
            t.check(!SkinSelectionController.isSelectionGesture([.control]))
            t.check(!SkinSelectionController.isSelectionGesture([.option]))
        }
    }

    private static func groupTests(_ t: AppTestRunner) {
        t.suite("App: skin selection: Ctrl-Option unions DragGroup membership and restores temporary window behavior") {
            guard let f = try load(t) else { return }
            f.app.changeSettings(of: f.a) {
                $0.draggable = false
                $0.clickThrough = true
                $0.keepOnScreen = true
                $0.onHover = 1
                $0.alphaValue = 96
            }
            let saved = f.a.state
            t.check(f.a.window.ignoresMouseEvents)
            t.equal(Set(f.a.runtime.snapshot.dragGroups), ["alpha", "beta"], "INI and config groups form a union")
            guard let press = AppSelfTest.mouseEvent(.leftMouseDown, f.a, x: 50, y: 40,
                                                       flags: [.control, .option]),
                  let release = AppSelfTest.mouseEvent(.leftMouseUp, f.a, x: 50, y: 40,
                                                       flags: [.control, .option]) else {
                return t.check(false, "a selection click")
            }
            f.a.view.mouseDown(with: press)
            t.equal(f.app.skinSelection.selectedConfigs, [], "selection waits for the button release")
            f.a.view.mouseUp(with: release)
            t.equal(Set(f.app.skinSelection.selectedConfigs), Set([f.a.config, f.b.config, f.c.config]))
            t.check(f.a.isSelected && f.b.isSelected && f.c.isSelected && !f.d.isSelected)
            t.equal(f.a.state, saved, "selection does not rewrite saved flags")
            t.check(!f.a.window.ignoresMouseEvents, "selection temporarily accepts pointer input")
            t.check(!f.a.isHovering, "selection suppresses hover hiding")
            let before = f.a.window.frame
            f.app.skinSelection.beginDrag(f.a, point: NSPoint(x: 50, y: 40), screen: .zero)
            f.app.skinSelection.drag(to: NSPoint(x: 30, y: -20), flags: [])
            f.app.skinSelection.endDrag()
            t.close(Double(f.a.window.frame.minX - before.minX), 30, "selection can move a non-draggable skin")
            t.close(Double(f.a.window.frame.minY - before.minY), -20)
            t.check(!f.a.isDragPressActive)
            f.app.skinSelection.toggle(f.a)
            t.check(!f.a.isSelected && f.b.isSelected && f.c.isSelected, "toggle removes only the chosen member")
            t.check(f.a.window.ignoresMouseEvents, "saved click-through resumes")
            t.equal(f.a.state.draggable, false)
            t.equal(f.a.state.keepOnScreen, true)
            t.equal(f.a.state.onHover, 1)
            t.equal(f.a.state.alphaValue, 96)
            f.app.skinSelection.clear()
            t.equal(f.app.skinSelection.selectedConfigs, [])
            t.check(f.all.allSatisfy { !$0.isSelected })
        }
    }

    private static func persistenceTests(_ t: AppTestRunner) {
        t.suite("App: skin selection: live zoom and position remain deferred on disk until deselection") {
            guard let f = try load(t) else { return }
            f.app.state.saveNow()
            let oldA = f.a.state, oldB = f.b.state, oldC = f.c.state
            f.app.skinSelection.toggle(f.a)
            setZoom(150, for: f.a, t)
            setZoom(180, for: f.b, t)
            guard let right = key(124, flags: []) else { return t.check(false, "arrow event") }
            t.check(f.app.skinSelection.keyDown(right))
            f.app.state.update(f.d.config) { $0.alphaValue = 77 }
            f.app.state.saveNow()
            var stored = AppState(fileURL: f.app.state.fileURL)
            t.equal(stored.skin(f.a.config), oldA, "even an explicit save retains the selected skin's earlier state")
            t.equal(stored.skin(f.b.config), oldB)
            t.equal(stored.skin(f.c.config), oldC)
            t.equal(stored.skin(f.d.config)?.alphaValue, 77, "unselected state still saves normally")
            t.equal(f.a.zoomOverridePercent, 150, "the running skin uses its new value immediately")
            t.equal(f.b.zoomOverridePercent, 180)
            f.app.skinSelection.remove(f.a)
            f.app.state.saveNow()
            stored = AppState(fileURL: f.app.state.fileURL)
            t.equal(stored.skin(f.a.config), f.a.state, "only the deselected skin is released for saving")
            t.equal(stored.skin(f.b.config), oldB)
            f.app.skinSelection.clear()
            f.app.state.saveNow()
            stored = AppState(fileURL: f.app.state.fileURL)
            t.equal(stored.skin(f.b.config), f.b.state)
            t.equal(stored.skin(f.c.config), f.c.state)
        }
    }

    private static func zoomDragTests(_ t: AppTestRunner) {
        t.suite("App: skin selection: two-pixel threshold and right or bottom resizing retain the top-left") {
            guard let f = try load(t) else { return }
            let selection = f.app.skinSelection
            selection.toggle(f.d)
            let pixel = 1 / max(1, f.d.window.backingScaleFactor)
            let before = f.d.window.frame
            selection.beginDrag(f.d, point: NSPoint(x: before.width - pixel, y: before.height / 2), screen: .zero)
            selection.drag(to: NSPoint(x: 1.5 * pixel, y: 0), flags: [])
            t.equal(f.d.zoomOverridePercent, nil, "movement below two physical pixels does nothing")
            t.equal(f.d.window.frame, before)
            selection.drag(to: NSPoint(x: 50, y: 0), flags: [])
            selection.endDrag()
            finished([f.d], t)
            t.equal(f.d.zoomOverridePercent, 150)
            t.equal(f.d.window.frame.size, NSSize(width: 150, height: 120))
            t.close(Double(f.d.window.frame.minX), Double(before.minX))
            t.close(Double(f.d.window.frame.maxY), Double(before.maxY))
            setZoom(100, for: f.d, t)
            let bottomBefore = f.d.window.frame
            selection.beginDrag(f.d, point: NSPoint(x: 50, y: 80 - pixel), screen: .zero)
            selection.drag(to: NSPoint(x: 0, y: -40), flags: [])
            selection.endDrag()
            finished([f.d], t)
            t.equal(f.d.zoomOverridePercent, 150)
            t.close(Double(f.d.window.frame.minX), Double(bottomBefore.minX))
            t.close(Double(f.d.window.frame.maxY), Double(bottomBefore.maxY))
        }
    }

    private static func layoutCaptureTests(_ t: AppTestRunner) {
        t.suite("App: skin selection: saving a layout captures live selected values while state persistence is deferred") {
            guard let f = try load(t) else { return }
            f.app.state.saveNow()
            let original = f.a.state
            f.app.skinSelection.toggle(f.a)
            setZoom(175, for: f.a, t)
            f.a.moveTo(x: 317, y: 241)
            t.close(f.a.topLeftPosition.x, 317)
            t.close(f.a.topLeftPosition.y, 241)
            t.equal(f.a.zoomOverridePercent, 175)
            let captured = LayoutStateCodec.capture(f.app.state.data, library: f.app.library, options: LayoutSaveOptions())
            let section = captured.section(named: f.a.config)
            t.equal(section?["Zoom"], "175", "capture reads live state rather than the persistence snapshot")
            t.equal(section?["WindowX"], "317")
            t.equal(section?["WindowY"], "241")
            try f.app.saveLayout(named: "Selected live", options: LayoutSaveOptions())
            let saved = try f.app.layoutStore.read(named: "Selected live").ini.section(named: f.a.config)
            t.equal(saved?["Zoom"], "175", "the actual Rainmeter.ini retains the live zoom")
            t.equal(saved?["WindowX"], "317")
            t.equal(saved?["WindowY"], "241")
            t.check(f.a.isSelected, "saving a layout does not end selection")
            f.app.state.saveNow()
            let persisted = AppState(fileURL: f.app.state.fileURL)
            t.equal(persisted.skin(f.a.config), original, "ordinary state saving still waits for deselection")
            t.equal(f.a.zoomOverridePercent, 175, "the running desktop keeps its edited values")
        }
    }

    private static func cornerTests(_ t: AppTestRunner) {
        t.suite("App: skin selection: corners lock the first axis and left-top zoom follows the size increment") {
            guard let f = try load(t) else { return }
            let selection = f.app.skinSelection
            selection.toggle(f.d)
            let pixel = 1 / max(1, f.d.window.backingScaleFactor)
            selection.beginDrag(f.d, point: NSPoint(x: 100 - pixel, y: 80 - pixel), screen: .zero)
            selection.drag(to: NSPoint(x: 20, y: -2), flags: [])
            selection.drag(to: NSPoint(x: 30, y: -70), flags: [])
            selection.endDrag()
            finished([f.d], t)
            t.equal(f.d.zoomOverridePercent, 130, "later vertical movement cannot change a horizontally locked corner")
            setZoom(100, for: f.d, t)
            let before = f.d.window.frame
            selection.beginDrag(f.d, point: .zero, screen: .zero)
            selection.drag(to: NSPoint(x: -10, y: 8), flags: [])
            selection.endDrag()
            finished([f.d], t)
            t.equal(f.d.zoomOverridePercent, 110)
            t.close(Double(f.d.window.frame.minX), Double(before.minX + 10), "left edge moves by the positive size increment")
            t.close(Double(f.d.window.frame.maxY), Double(before.maxY - 8), "top edge moves down by the height increment")
        }
    }

    private static func multiSelectionTests(_ t: AppTestRunner) {
        t.suite("App: skin selection: group resizing adds the same percentage delta and clamps each member") {
            guard let f = try load(t) else { return }
            setZoom(150, for: f.b, t)
            setZoom(480, for: f.c, t)
            let selection = f.app.skinSelection
            selection.toggle(f.a)
            let positions = [f.a, f.b, f.c].map { NSPoint(x: $0.window.frame.minX, y: $0.window.frame.maxY) }
            let pixel = 1 / max(1, f.a.window.backingScaleFactor)
            selection.beginDrag(f.a, point: NSPoint(x: 100 - pixel, y: 40), screen: .zero)
            selection.drag(to: NSPoint(x: 50, y: 0), flags: [])
            selection.endDrag()
            finished([f.a, f.b, f.c], t)
            t.equal([f.a.zoomOverridePercent, f.b.zoomOverridePercent, f.c.zoomOverridePercent], [150, 200, 500])
            for (c, point) in zip([f.a, f.b, f.c], positions) {
                t.close(Double(c.window.frame.minX), Double(point.x))
                t.close(Double(c.window.frame.maxY), Double(point.y))
            }
            setZoom(100, for: f.a, t)
            setZoom(20, for: f.b, t)
            setZoom(100, for: f.c, t)
            selection.beginDrag(f.a, point: NSPoint(x: 100 - pixel, y: 40), screen: .zero)
            selection.drag(to: NSPoint(x: -50, y: 0), flags: [])
            selection.endDrag()
            finished([f.a, f.b, f.c], t)
            t.equal([f.a.zoomOverridePercent, f.b.zoomOverridePercent, f.c.zoomOverridePercent], [50, 10, 50])
            t.equal(f.d.zoomOverridePercent, nil, "the unselected skin is untouched")
        }

        t.suite("App: skin selection: a member at the zoom limit still follows left-top group displacement") {
            guard let f = try load(t) else { return }
            setZoom(500, for: f.c, t)
            let selection = f.app.skinSelection
            selection.toggle(f.a)
            let positions = [f.a, f.b, f.c].map { NSPoint(x: $0.window.frame.minX, y: $0.window.frame.maxY) }
            let limitedSize = f.c.window.frame.size
            selection.beginDrag(f.a, point: .zero, screen: .zero)
            selection.drag(to: NSPoint(x: -20, y: 16), flags: [])
            selection.endDrag()
            finished([f.a, f.b, f.c], t)
            t.equal([f.a.zoomOverridePercent, f.b.zoomOverridePercent, f.c.zoomOverridePercent], [120, 120, 500])
            t.equal(f.c.window.frame.size, limitedSize, "a capped member needs no size change")
            for (c, point) in zip([f.a, f.b, f.c], positions) {
                t.close(Double(c.window.frame.minX), Double(point.x + 20), "all members follow the primary width increment")
                t.close(Double(c.window.frame.maxY), Double(point.y - 16), "all members follow the primary height increment")
            }
        }
    }

    private static func inputTests(_ t: AppTestRunner) {
        t.suite("App: skin selection: nudge keys and outside presses preserve or clear the selected group") {
            guard let f = try load(t) else { return }
            let selection = f.app.skinSelection
            let source = FakePointerEventSource()
            selection.use(source)
            selection.toggle(f.a)
            t.equal(source.global, [.leftMouseDown, .rightMouseDown], "only pointer presses need a global monitor")
            t.equal(source.local, [.leftMouseDown, .rightMouseDown])
            let before = f.a.window.frame
            guard let right = key(124, flags: []), let up = key(126, flags: [.control]),
                  let down = key(125, flags: []), let left = key(123, flags: [.control]) else {
                return t.check(false, "arrow keys")
            }
            for event in [right, up, down, left] { t.check(selection.keyDown(event)) }
            t.close(Double(f.a.window.frame.minX), Double(before.minX - 9), "one point, or ten with Control")
            t.close(Double(f.a.window.frame.minY), Double(before.minY + 9))
            guard let local = AppSelfTest.mouseEvent(.leftMouseDown, f.a, x: 50, y: 40),
                  let modified = outside(flags: [.control, .option]), let outsideEvent = outside(flags: []) else {
                return t.check(false, "synthetic presses")
            }
            t.check(source.send(local, local: true))
            t.check(selection.contains(f.a.config), "clicking another selected skin preserves selection")
            t.check(source.send(modified, local: false))
            t.check(selection.contains(f.a.config), "Ctrl-Option preserves selection across apps")
            t.check(source.send(outsideEvent, local: false))
            t.equal(selection.selectedConfigs, [])
            t.check(!source.isWatching, "the outside monitor is removed once nothing is selected")
            t.equal(source.badStops, 0)
            t.check(!selection.keyDown(right), "unselected arrow keys are not consumed")
        }
    }

    private static func forceTests(_ t: AppTestRunner) {
        t.suite("App: skin selection: forced default zoom blocks resize without leaving an unfinished drag") {
            guard let f = try load(t) else { return }
            setZoom(140, for: f.d, t)
            f.app.setDefaultZoom(percent: 125, force: true)
            t.check(AppSelfTest.spin { f.d.runtime.snapshot.zoomFactor == 1.25 }, "the forced default reached the runtime")
            let selection = f.app.skinSelection
            selection.toggle(f.d)
            let before = f.d.window.frame
            let pixel = 1 / max(1, f.d.window.backingScaleFactor)
            selection.beginDrag(f.d, point: NSPoint(x: before.width - pixel, y: before.height / 2), screen: .zero)
            selection.drag(to: NSPoint(x: 50, y: 0), flags: [])
            selection.endDrag()
            finished([f.d], t)
            t.equal(f.d.window.frame, before)
            t.equal(f.d.zoomOverridePercent, 140, "the explicit override is retained while Force is enabled")
            t.equal(f.d.effectiveZoomFactor, 1.25)
            f.app.setDefaultZoom(percent: nil, force: false)
            t.check(AppSelfTest.spin { f.d.runtime.snapshot.zoomFactor == 1.4 }, "turning Force off restores the override")
        }
    }

    private static func menuTrackingTests(_ t: AppTestRunner) {
        t.suite("App: skin selection: menu tracking preserves local menu presses but not global outside presses") {
            guard let f = try load(t),
                  let foreignWindow = AppSelfTest.mouseEvent(.leftMouseDown, f.d, x: 50, y: 40),
                  let menuWindow = outside(flags: []) else { return }
            let selection = f.app.skinSelection
            let source = FakePointerEventSource()
            selection.use(source)
            selection.toggle(f.a)
            selection.beginMenuTracking()
            t.check(source.send(foreignWindow, local: true))
            t.check(selection.contains(f.a.config), "a local press outside selected windows may belong to a menu")
            t.check(source.send(menuWindow, local: true))
            t.check(selection.contains(f.a.config), "menu windows without a skin controller also preserve selection")
            selection.endMenuTracking()
            t.check(source.send(foreignWindow, local: true))
            t.equal(selection.selectedConfigs, [], "the same local event clears selection after menu tracking ends")
            selection.toggle(f.a)
            selection.beginMenuTracking()
            t.check(source.send(menuWindow, local: false))
            t.equal(selection.selectedConfigs, [], "a click in another app clears selection even while a menu tracks")
            selection.endMenuTracking()
            t.check(!source.isWatching)
            t.equal(source.badStops, 0)
        }
    }

    private static func setZoom(_ percent: Int, for c: SkinWindowController, _ t: AppTestRunner) {
        var completed = false
        c.requestZoom(percent: percent) { completed = true }
        t.check(AppSelfTest.spin { completed && c.runtime.snapshot.zoomFactor == Double(percent) / 100 },
                "zoom request completed at \(percent)%")
        t.equal(c.zoomOverridePercent, percent)
    }

    private static func finished(_ controllers: [SkinWindowController], _ t: AppTestRunner) {
        t.check(AppSelfTest.spin {
            controllers.allSatisfy { !$0.isDragPressActive && $0.zoomPositionOverride == nil }
        }, "all zoom acknowledgements release the drag and its temporary position")
    }

    private static func key(_ code: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
    }

    private static func outside(flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 1000, y: 500), modifierFlags: flags,
                          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
}
