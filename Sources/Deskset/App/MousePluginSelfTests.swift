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
    }
}
