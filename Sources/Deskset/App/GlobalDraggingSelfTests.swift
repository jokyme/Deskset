import AppKit
import DesksetCore

/// Global mouse-dragging settings are exercised through temporary app state and actual window input.
enum GlobalDraggingSelfTests {
    static func run(_ t: AppTestRunner) {
        settingsTests(t)
        mouseTests(t)
        activePressTests(t)
        selectedTests(t)
    }

    private static func settingsTests(_ t: AppTestRunner) {
        t.suite("App: Global dragging: General checkbox persists without rewriting skin flags") {
            guard let (app, a, b) = try fixture(t) else { return }
            app.changeSettings(of: b) { $0.draggable = false }
            let aState = a.state, bState = b.state
            CodeEditorRoutingSelfTests.withFakes(CodeEditorRoutingSelfTests.FakeLocator(),
                                                 CodeEditorRoutingSelfTests.RecordingOpener()) {
                let settings = SettingsWindowController(app: app)
                defer { settings.close() }
                settings.select(.general)
                t.equal(settings.disableDraggingBox.title, "Disable dragging")
                t.equal(settings.disableDraggingBox.state, .off)
                settings.disableDraggingBox.performClick(nil)
                t.check(app.state.disableDragging)
                t.equal(settings.disableDraggingBox.state, .on)
                app.state.saveNow()
                t.check(AppState(fileURL: app.state.fileURL).disableDragging)
                t.equal(a.state, aState)
                t.equal(b.state, bState, "the global lock keeps each skin's own Draggable value")
                app.state.setDisableDragging(false)
                t.check(AppSelfTest.spin { settings.disableDraggingBox.state == .off },
                        "an open General pane follows a change from elsewhere")
                t.equal(a.state.draggable, true)
                t.equal(b.state.draggable, false)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    settings.window?.appearance = NSAppearance(named: appearance)
                    guard let content = settings.window?.contentView else {
                        return t.check(false, "General pane exists")
                    }
                    content.layoutSubtreeIfNeeded()
                    let rect = settings.disableDraggingBox.convert(settings.disableDraggingBox.bounds, to: content)
                    t.check(rect.width > 0 && rect.height > 0 && content.bounds.contains(rect),
                            "\(appearance.rawValue): the global dragging control is fully visible")
                    t.check(settings.snapshot() != nil)
                }
            }
        }
    }

    private static func mouseTests(_ t: AppTestRunner) {
        t.suite("App: Global dragging: mouse movement is locked while click actions and Move bangs still work") {
            guard let (app, a, b) = try fixture(t) else { return }
            let before = a.window.frame
            app.state.setDisableDragging(true)
            drag(a, by: NSPoint(x: 40, y: -20), t)
            t.equal(a.window.frame, before)
            t.check(!a.isDragPressActive)
            t.equal(a.state.draggable, true)
            t.equal(a.runtime.exclusive { $0.variable("Clicked") }, "0")
            click(a, x: 15, y: 15, t)
            t.equal(a.runtime.exclusive { $0.variable("Clicked") }, "1", "locking windows leaves skin buttons usable")
            a.runtime.send(.execute("[!Move 480 350]", section: nil))
            t.check(AppSelfTest.spin { abs(a.topLeftPosition.x - 480) < 0.01 && abs(a.topLeftPosition.y - 350) < 0.01 },
                    "programmatic movement is independent of the mouse setting")
            app.deactivate(config: b.config)
            guard let loaded = app.activate(config: b.config, file: b.file) else {
                return t.check(false, "a skin loads while dragging is disabled")
            }
            t.check(AppSelfTest.spin { loaded.isStarted })
            loaded.pauseUpdates()
            let loadedFrame = loaded.window.frame
            drag(loaded, by: NSPoint(x: 35, y: 15), t)
            t.equal(loaded.window.frame, loadedFrame, "newly loaded skins follow the same global setting")
            t.equal(loaded.state.draggable, true)
            app.state.setDisableDragging(false)
            let unlocked = a.window.frame
            drag(a, by: NSPoint(x: 40, y: -20), t)
            t.close(a.window.frame.minX - unlocked.minX, 40)
            t.close(a.window.frame.minY - unlocked.minY, -20)
            t.check(!a.isDragPressActive)
            app.changeSettings(of: loaded) { $0.draggable = false }
            drag(loaded, by: NSPoint(x: 35, y: 15), t)
            t.equal(loaded.window.frame, loadedFrame, "turning the global setting off preserves a skin's own lock")
        }
    }

    private static func activePressTests(_ t: AppTestRunner) {
        t.suite("App: Global dragging: enabling the lock ends an ordinary drag without resuming its old origin") {
            guard let (app, a, _) = try fixture(t) else { return }
            let savedPointer = SkinView.pointerLocation
            var pointer = NSPoint(x: 1000, y: 700)
            SkinView.pointerLocation = { pointer }
            defer { SkinView.pointerLocation = savedPointer }
            send(.leftMouseDown, a, t)
            t.check(a.isDragPressActive)
            app.state.setDisableDragging(true)
            pointer.x += 40
            send(.leftMouseDragged, a, t)
            let locked = a.window.frame
            t.check(!a.isDragPressActive)
            app.state.setDisableDragging(false)
            pointer.x += 40
            send(.leftMouseDragged, a, t)
            t.equal(a.window.frame, locked, "a new mouse press is required after locking an active press")
            send(.leftMouseUp, a, t)
            t.check(!a.isDragPressActive)
            drag(a, by: NSPoint(x: 30, y: 10), t)
            t.close(a.window.frame.minX - locked.minX, 30)
            t.close(a.window.frame.minY - locked.minY, 10)

            send(.leftMouseDown, a, t)
            pointer.x += 20
            send(.leftMouseDragged, a, t)
            let moved = a.window.frame
            app.state.setDisableDragging(true)
            app.state.setDisableDragging(false)
            pointer.x += 80
            send(.leftMouseDragged, a, t)
            t.equal(a.window.frame, moved, "on/off changes between drag events do not revive the old gesture")
            send(.leftMouseUp, a, t)
            t.check(!a.isDragPressActive)
        }
    }

    private static func selectedTests(_ t: AppTestRunner) {
        t.suite("App: Global dragging: selected skins keep their own flags while the global mouse lock applies") {
            guard let (app, a, b) = try fixture(t) else { return }
            app.changeSettings(of: b) { $0.draggable = false }
            app.skinSelection.toggle(a)
            app.skinSelection.toggle(b)
            let beforeA = a.window.frame, beforeB = b.window.frame
            app.state.setDisableDragging(true)
            app.skinSelection.beginDrag(a, point: NSPoint(x: 60, y: 40), screen: .zero)
            app.skinSelection.drag(to: NSPoint(x: 40, y: -20), flags: [])
            app.skinSelection.endDrag()
            t.equal(a.window.frame, beforeA)
            t.equal(b.window.frame, beforeB)
            t.check(!a.isDragPressActive && !b.isDragPressActive)
            t.equal(a.state.draggable, true)
            t.equal(b.state.draggable, false)
            app.state.setDisableDragging(false)
            app.skinSelection.beginDrag(a, point: NSPoint(x: 60, y: 40), screen: .zero)
            app.skinSelection.drag(to: NSPoint(x: 40, y: -20), flags: [])
            app.skinSelection.endDrag()
            t.close(a.window.frame.minX - beforeA.minX, 40)
            t.close(b.window.frame.minX - beforeB.minX, 40)
            t.equal(b.state.draggable, false, "selection's temporary override never changes the stored lock")
            app.skinSelection.beginDrag(a, point: NSPoint(x: 60, y: 40), screen: .zero)
            app.skinSelection.drag(to: NSPoint(x: 20, y: 10), flags: [])
            let midA = a.window.frame, midB = b.window.frame
            app.state.setDisableDragging(true)
            t.check(!a.isDragPressActive && !b.isDragPressActive, "the lock ends a group drag already in progress")
            app.state.setDisableDragging(false)
            app.skinSelection.drag(to: NSPoint(x: 90, y: 90), flags: [])
            app.skinSelection.endDrag()
            t.equal(a.window.frame, midA)
            t.equal(b.window.frame, midB, "an old group gesture cannot resume after toggling the lock")
            app.skinSelection.clear()
        }
    }

    private static func fixture(_ t: AppTestRunner) throws -> (AppController, SkinWindowController, SkinWindowController)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        var skins: [SkinWindowController] = []
        for name in ["A", "B"] {
            let config = "GlobalDragging\\" + name
            let folder = SkinLibrary.directory(for: config, root: app.skinsDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
            [Rainmeter]
            Update=-1
            [Variables]
            Clicked=0
            [Face]
            Meter=Image
            W=120
            H=80
            SolidColor=40,90,150,255
            [Action]
            Meter=Image
            X=0
            Y=0
            W=30
            H=30
            SolidColor=90,150,40,255
            LeftMouseUpAction=[!SetVariable Clicked 1]
            """.write(to: folder.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
            app.state.update(config) {
                $0.file = "Skin.ini"
                $0.x = name == "A" ? 200 : 400
                $0.y = 200
                $0.keepOnScreen = false
                $0.snapEdges = false
            }
            guard let skin = app.activate(config: config, file: "Skin.ini") else {
                t.check(false, "global dragging fixture loads")
                return nil
            }
            t.check(AppSelfTest.spin { skin.isStarted })
            skin.pauseUpdates()
            skins.append(skin)
        }
        t.atSuiteEnd { app.skinSelection.clear(); app.stopAllForTermination() }
        return (app, skins[0], skins[1])
    }

    private static func send(_ type: NSEvent.EventType, _ skin: SkinWindowController, _ t: AppTestRunner,
                             x: Double = 60, y: Double = 40, flags: NSEvent.ModifierFlags = []) {
        guard let event = AppSelfTest.mouseEvent(type, skin, x: x, y: y, flags: flags) else {
            return t.check(false, "mouse event exists")
        }
        switch type {
        case .leftMouseDown: skin.view.mouseDown(with: event)
        case .leftMouseDragged: skin.view.mouseDragged(with: event)
        case .leftMouseUp: skin.view.mouseUp(with: event)
        default: t.check(false, "unsupported test event")
        }
    }

    private static func click(_ skin: SkinWindowController, x: Double, y: Double, _ t: AppTestRunner) {
        send(.leftMouseDown, skin, t, x: x, y: y)
        send(.leftMouseUp, skin, t, x: x, y: y)
    }

    private static func drag(_ skin: SkinWindowController, by amount: NSPoint, _ t: AppTestRunner) {
        let savedPointer = SkinView.pointerLocation
        var pointer = NSPoint(x: 1000, y: 700)
        SkinView.pointerLocation = { pointer }
        defer { SkinView.pointerLocation = savedPointer }
        send(.leftMouseDown, skin, t)
        pointer.x += amount.x
        pointer.y += amount.y
        send(.leftMouseDragged, skin, t)
        send(.leftMouseUp, skin, t)
    }
}
