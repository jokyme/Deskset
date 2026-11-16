import AppKit
import DesksetCore

/// Plugin=Mouse through the skin window: real mouse events sent to `SkinView` reach the measure before the meters.
/// Fixture: TestSkins/App/MousePlugin.
extension AppSelfTest {
    static func mousePluginTests(_ t: AppTestRunner) {
        t.suite("App: Plugin=Mouse gets the skin window's mouse input first") {
            guard let app = try makeApp(t), let c = app.activate(config: "App\\MousePlugin", file: nil) else { return }
            let view = c.view
            func v(_ name: String) -> String { c.skin.variable(name) ?? "" }
            func send(_ type: NSEvent.EventType, _ x: Double, _ y: Double, clickCount: Int = 1,
                      flags: NSEvent.ModifierFlags = []) {
                guard let event = mouseEvent(type, c, x: x, y: y, clickCount: clickCount, flags: flags) else {
                    t.check(false, "\(type) event")
                    return
                }
                switch type {
                case .mouseMoved: view.mouseMoved(with: event)
                case .leftMouseDown: view.mouseDown(with: event)
                case .leftMouseDragged: view.mouseDragged(with: event)
                case .leftMouseUp: view.mouseUp(with: event)
                default: t.check(false, "unexpected \(type)")
                }
            }
            t.equal(c.skin.issues, [], "Plugin=Mouse is supported")
            let mouse = c.skin.measure(named: "MeasureMouse")
            t.equal(mouse?.disabled, true)

            // Over the track: its MouseOverAction enables the measure.
            send(.mouseMoved, 60, 30)
            t.equal(mouse?.disabled, false, "enabled by the track's MouseOverAction")
            // A press on the track: the measure first, then the meter.
            send(.leftMouseDown, 75, 30)
            t.equal(v("Order"), "plugin-down meter-down ")
            t.equal(v("Value"), "25", "$MouseX$ relative to the skin")
            t.equal(view.dragAllowed, false, "the track's LeftMouseDownAction keeps the skin in place")
            t.equal(view.pointerPresses, [.left])
            // Dragging past the right edge of the 200-point window, then past the left one.
            send(.leftMouseDragged, 260, 30)
            t.equal(v("Value"), "100", "the drag is followed outside the skin")
            // Within UpdateRate=20 of the last one, this position may wait; the release runs it first at the latest.
            send(.leftMouseDragged, -40, 30)
            send(.leftMouseUp, -40, 30)
            t.equal(v("Value"), "0", "the last drag position ran before the release")
            t.equal(v("Order"), "plugin-down meter-down plugin-up ", "no meter under the release")
            t.equal(v("Released"), "1")
            t.equal(mouse?.disabled, true, "its LeftMouseUpAction disabled it")
            t.check(view.pointerPresses.isEmpty)

            // ⌘-presses (the CTRL override) move the skin: the measure does not see them.
            c.skin.execute("[!EnableMeasure MeasureMouse][!SetVariable Order \"\"]", from: nil)
            send(.leftMouseDown, 75, 30, flags: .command)
            send(.leftMouseDragged, 90, 30, flags: .command)
            send(.leftMouseUp, 90, 30, flags: .command)
            t.equal(v("Order"), "", "no action for a ⌘-press")
            t.equal(v("Value"), "0")
            t.check(view.pointerPresses.isEmpty)

            // A double click: DoubleClick and Down actions of the measure, then the meter's.
            send(.leftMouseDown, 100, 30, clickCount: 2)
            t.equal(v("Order"), "plugin-double plugin-down meter-down ")
            t.equal(v("Value"), "50")
            send(.leftMouseUp, 100, 30, clickCount: 2)
            t.equal(v("Order"), "plugin-double plugin-down meter-down plugin-up meter-up ")

            // A press whose release never reached the window is released by the next move.
            c.skin.execute("[!EnableMeasure MeasureMouse][!SetVariable Order \"\"]", from: nil)
            send(.leftMouseDown, 60, 30)
            send(.mouseMoved, 61, 30)
            t.equal(v("Order"), "plugin-down meter-down plugin-up ", "the measure's LeftMouseUpAction ran")
            t.check(view.pointerPresses.isEmpty)
        }

        t.suite("App: Mouse capture overlay covers multiple monitors, waits for held release, and handles Esc") {
            final class FakeCaptureMonitorSource: MouseCaptureMonitorSource {
                var handler: ((NSEvent, Bool) -> NSEvent?)?
                func start(handler: @escaping (NSEvent, Bool) -> NSEvent?) { self.handler = handler }
                func stop() { handler = nil }
                func send(_ event: NSEvent, local: Bool) -> NSEvent? { handler?(event, local) }
            }
            guard let app = try makeApp(t), let c = app.activate(config: "App\\MousePlugin", file: nil) else { return }
            let capture = app.mouseCapture
            let monitor = FakeCaptureMonitorSource()
            capture.use(monitor)
            capture.screensProvider = {
                [
                    WindowGeometry.Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                          visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)),
                    WindowGeometry.Screen(frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
                                          visibleFrame: CGRect(x: 1920, y: 0, width: 2560, height: 1415)),
                ]
            }
            defer {
                capture.screensProvider = { WindowGeometry.currentScreens() }
                capture.pressedButtonsProvider = { NSEvent.pressedMouseButtons }
                capture.cancel(notifySkin: false)
            }
            var heldMask = 1 << 0
            capture.pressedButtonsProvider = { heldMask }
            c.skin.execute(
                "[!EnableMeasure MeasureMouse][!SetOption MeasureMouse RelativeToSkin 0]"
                + "[!SetOption MeasureMouse CaptureOverlayCursorName ARROW]"
                + "[!SetOption MeasureMouse CaptureOverlayColor 10,20,30,40]"
                + "[!SetOption MeasureMouse LeftMouseUpAction \"[!SetVariable Cap $MouseX$,$MouseY$]\"]"
                + "[!UpdateMeasure MeasureMouse]",
                from: nil
            )
            c.skin.execute("[!Mouse:StartCapture MeasureMouse]", from: nil)
            t.equal(capture.activeOverlayPanels.count, 2, "one overlay panel created per screen")
            t.equal(capture.activeOverlayPanels.map(\.frame), [
                CGRect(x: 0, y: 0, width: 1920, height: 1080),
                CGRect(x: 1920, y: 0, width: 2560, height: 1440),
            ], "overlay panels cover every monitor")
            t.check(capture.isWaitingForInitialRelease)
            t.check(SkinCursors.cursor(named: "ARROW", cursorsDirectory: nil) === NSCursor.arrow)

            // Releasing the initially held button clears the hold without completing capture.
            let heldRelease = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 50, y: 50),
                                                 modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            _ = monitor.send(heldRelease, local: true)
            heldMask = 0
            t.check(!capture.isWaitingForInitialRelease)
            t.equal(c.skin.variable("Cap"), nil)
            t.check(capture.activeSession != nil)

            // Next click completes capture against live screens and invokes LeftMouseUpAction.
            let liveScreens = WindowGeometry.currentScreens()
            capture.screensProvider = { liveScreens }
            let primary = liveScreens[0]
            let primaryH = WindowGeometry.primaryHeight(liveScreens)
            let targetAppKitY = primaryH - ((primaryH - primary.frame.maxY) + 100)
            let targetAppKitX = primary.frame.minX + 100
            let secondClick = NSEvent.mouseEvent(with: .leftMouseUp,
                                                 location: NSPoint(x: targetAppKitX, y: targetAppKitY),
                                                 modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            _ = monitor.send(secondClick, local: false)
            t.equal(c.skin.variable("Cap"), "100,100")
            t.check(capture.activeSession == nil)
            t.equal(capture.activeOverlayPanels.count, 0)

            // Escape cancels capture without executing any mouse action.
            c.skin.execute("[!SetVariable Cap \"none\"][!Mouse:StartCapture MeasureMouse]", from: nil)
            t.check(capture.activeSession != nil)
            let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "\u{1B}",
                                       charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
            t.check(monitor.send(esc, local: true) == nil, "Esc consumed and cancels capture")
            t.check(capture.activeSession == nil)
            t.equal(c.skin.variable("Cap"), "none")
        }
    }
}
