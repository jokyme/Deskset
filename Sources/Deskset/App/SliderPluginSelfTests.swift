import AppKit
import DesksetCore

/// Plugin=Slider through the skin window: real right- and middle-button events sent to `SkinView` reach the measures
/// that track those buttons, before the meters. Fixture: TestSkins/App/SliderPlugin.
extension AppSelfTest {
    static func sliderPluginTests(_ t: AppTestRunner) {
        t.suite("App: Plugin=Slider follows the right and the middle button through the skin window") {
            guard let app = try makeApp(t), let c = app.activate(config: "App\\SliderPlugin", file: nil) else { return }
            let view = c.view
            func v(_ name: String) -> String { c.skin.variable(name) ?? "" }
            func send(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
                guard var event = mouseEvent(type, c, x: x, y: y) else {
                    t.check(false, "\(type) event")
                    return
                }
                // AppKit makes every synthesized button event button 0; the middle button is 2. Going through a
                // CGEvent sets it, and AppKit reads that event's location as window points from the top-left corner.
                if [.otherMouseDown, .otherMouseDragged, .otherMouseUp].contains(type) {
                    guard let cg = event.cgEvent else { return }
                    cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                    cg.location = CGPoint(x: x, y: y)
                    guard let middle = NSEvent(cgEvent: cg), middle.buttonNumber == 2,
                          middle.locationInWindow == event.locationInWindow else {
                        t.check(false, "middle-button \(type) event at \(x), \(y)")
                        return
                    }
                    event = middle
                }
                switch type {
                case .rightMouseDown: view.rightMouseDown(with: event)
                case .rightMouseDragged: view.rightMouseDragged(with: event)
                case .rightMouseUp: view.rightMouseUp(with: event)
                case .otherMouseDown: view.otherMouseDown(with: event)
                case .otherMouseDragged: view.otherMouseDragged(with: event)
                case .otherMouseUp: view.otherMouseUp(with: event)
                default: t.check(false, "unexpected \(type)")
                }
            }
            t.equal(c.skin.issues, [], "Plugin=Slider is supported")

            // A right press on the track: the measure first, then the meter; dragged past the right edge of the
            // 200-point window. (The track's RightMouseDownAction keeps the skin menu closed.)
            send(.rightMouseDown, 75, 30)
            t.equal(v("Right"), "25", "$MouseX$ relative to the skin")
            t.equal(v("Order"), "right-click meter-rightdown ")
            send(.rightMouseDragged, 260, 30)
            send(.rightMouseUp, 260, 30)
            t.equal(v("Right"), "100", "the drag is followed outside the skin, and its last position runs first")
            t.equal(v("Order"), "right-click meter-rightdown right-release ")
            // On the background: the measure's ReleaseAction, then the background's RightMouseUpAction.
            send(.rightMouseDown, 20, 10)
            send(.rightMouseUp, 20, 10)
            t.equal(v("Right"), "0")
            t.equal(v("Order"), "right-click meter-rightdown right-release right-click right-release meter-rightup ")

            // The middle button: only the measure that tracks it, and below the skin too.
            c.skin.setVariable("Order", "")
            send(.otherMouseDown, 100, 30)
            send(.otherMouseDragged, 100, 90)
            send(.otherMouseUp, 100, 90)
            t.equal(v("Middle"), "90")
            t.equal(v("Order"), "middle-click meter-middledown middle-release ")
            t.equal(v("Right"), "0", "the right button's measure did not react")
            t.check(view.pointerPresses.isEmpty)
        }
    }
}
