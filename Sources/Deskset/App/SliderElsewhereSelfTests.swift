import AppKit
import DesksetCore

/// A stand-in for the NSEvent monitors: records what `OutsidePointerMonitor` asks it to watch and hands it synthetic
/// events. Self-tests never watch the real mouse (CI has no user, and nothing may depend on real input).
final class FakePointerEventSource: PointerEventSource {
    private final class Watch {
        let global: NSEvent.EventTypeMask
        let local: NSEvent.EventTypeMask
        let handler: (NSEvent, Bool) -> Void

        init(global: NSEvent.EventTypeMask, local: NSEvent.EventTypeMask, handler: @escaping (NSEvent, Bool) -> Void) {
            self.global = global
            self.local = local
            self.handler = handler
        }
    }
    private var watches: [Watch] = []
    /// What all the monitors watch now together.
    var global: NSEvent.EventTypeMask { watches.reduce(into: []) { $0.formUnion($1.global) } }
    var local: NSEvent.EventTypeMask { watches.reduce(into: []) { $0.formUnion($1.local) } }
    private(set) var starts = 0
    private(set) var stops = 0
    /// A stop with a token that is not watching (a monitor removed twice, or never added).
    private(set) var badStops = 0
    /// A monitor started for an event type another one already watches: that event would be handled twice.
    private(set) var overlaps = 0
    var pointerLocation = NSPoint.zero
    var pressedButtons = 0

    var isWatching: Bool { !watches.isEmpty }
    var monitors: Int { watches.count }

    func startWatching(global: NSEvent.EventTypeMask, local: NSEvent.EventTypeMask,
                       handler: @escaping (NSEvent, Bool) -> Void) -> AnyObject {
        if !global.isDisjoint(with: self.global) || !local.isDisjoint(with: self.local) { overlaps += 1 }
        starts += 1
        let watch = Watch(global: global, local: local, handler: handler)
        watches.append(watch)
        return watch
    }

    func stopWatching(_ token: AnyObject) {
        guard let index = watches.firstIndex(where: { $0 === token }) else {
            badStops += 1
            return
        }
        stops += 1
        watches.remove(at: index)
    }

    /// Hands an event to the monitors as NSEvent would: to each that watches its type, `local` for Deskset's own
    /// windows. False when none does.
    @discardableResult
    func send(_ event: NSEvent, local isLocal: Bool) -> Bool {
        let type = NSEvent.EventTypeMask(type: event.type)
        let handlers = watches.filter { (isLocal ? $0.local : $0.global).contains(type) }.map(\.handler)
        for handler in handlers { handler(event, isLocal) }
        return !handlers.isEmpty
    }
}

/// Plugin=Slider sees the mouse anywhere on the screen: `OutsidePointerMonitor` watches it while a running skin asks
/// for it and hands it to every skin but the one whose window got it. Fixture: TestSkins/App/SliderElsewhere (and
/// TestSkins/App/SliderPlugin as the other skin).
extension AppSelfTest {
    static func sliderElsewhereTests(_ t: AppTestRunner) {
        t.suite("App: Plugin=Slider sees clicks elsewhere on the screen, and its own window's only once") {
            guard let app = try makeApp(t), let c = app.activate(config: "App\\SliderElsewhere", file: nil) else {
                return
            }
            t.atSuiteEnd { app.stopAllForTermination() }
            let monitor = app.outsidePointer
            t.check(monitor.source == nil, "a headless app has no event source…")
            t.equal(c.skin.outsidePointerNeeds, OutsidePointerNeeds(buttons: [.left, .right], dragButtons: [.left]))
            t.check(!monitor.isWatching, "…so it never watches the real mouse")
            let fake = FakePointerEventSource()
            monitor.use(fake)
            t.check(fake.isWatching, "a running skin asks for it")
            t.equal(fake.global, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp],
                    "other apps: the tracked buttons; no drags before a press there, no moves without a MoveAction")
            t.equal(fake.local, [.leftMouseDown, .rightMouseDown], "Deskset's windows: presses (their rest is followed)")
            func v(_ name: String, _ skin: SkinController = c) -> String { skin.skin.variable(name) ?? "" }
            func flush(line: UInt = #line) { waitFor(t, "input delivered", line: line) { monitor.queue.isEmpty } }
            func global(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
                guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    t.check(false, "\(type) event")
                    return
                }
                t.check(event.window == nil && fake.send(event, local: false), "\(type) watched in other apps")
            }
            /// An event dispatched to one of Deskset's windows, at a screen point.
            func inWindow(_ type: NSEvent.EventType, _ window: NSWindow, _ x: Double, _ y: Double) -> NSEvent? {
                let p = window.convertPoint(fromScreen: NSPoint(x: x, y: y))
                let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 1)
                t.check(event?.window === window, "\(type) event in its window")
                return event
            }

            // The skin's window at (300, 400)–(500, 500) in screen coordinates: its top-left corner is (300, 500).
            c.window.setFrame(NSRect(x: 300, y: 400, width: 200, height: 100), display: false)
            global(.leftMouseDown, 250.5, 450.5)
            t.equal(v("Log"), "", "delivered on the next run loop turn")
            t.equal(fake.monitors, 1, "no monitor added from a monitor's handler")
            flush()
            t.equal(monitor.dragMask, .leftMouseDragged, "a press held in another app: its drags are watched (DragAction)")
            t.equal(fake.monitors, 2, "by a monitor of their own")
            global(.leftMouseDragged, 260, 440)
            global(.leftMouseUp, 270, 430)
            flush()
            t.equal(v("Log"), "click -50,49;drag -40,60;release -30,70;",
                    "$MouseX$ / $MouseY$ from the skin's top-left corner, left of and below it; no meter action")
            t.check(monitor.dragMask.isEmpty && fake.monitors == 1 && !fake.global.contains(.leftMouseDragged),
                    "released: its drags are no longer watched")
            global(.rightMouseDown, 250, 450)
            flush()
            t.check(monitor.dragMask.isEmpty && fake.monitors == 1, "a press whose drags no action wants: none watched")
            global(.rightMouseUp, 250, 450)
            flush()
            c.skin.setVariable("Screen", "")

            // A press on the skin's own window: SkinView reports it; the monitor's copy is not delivered again.
            c.skin.setVariable("Log", "")
            fake.pressedButtons = 1
            fake.pointerLocation = NSPoint(x: 320, y: 480)
            if let down = inWindow(.leftMouseDown, c.window, 320, 480) {
                t.check(fake.send(down, local: true))
                c.view.mouseDown(with: down)
            }
            flush()
            t.equal(v("Log"), "click 20,20;meter-down;", "one ClickAction, then the meter's")
            t.equal(monitor.followed, [.left: c.window.windowNumber], "its release is followed for the other skins")
            fake.pointerLocation = NSPoint(x: 330, y: 470)
            if let drag = inWindow(.leftMouseDragged, c.window, 330, 470) {
                t.check(!fake.send(drag, local: true), "drags in Deskset's windows are not watched: they are followed")
                c.view.mouseDragged(with: drag)
            }
            fake.pressedButtons = 0
            if let up = inWindow(.leftMouseUp, c.window, 330, 470) { c.view.mouseUp(with: up) }
            waitFor(t, "release followed") { monitor.followed.isEmpty && monitor.queue.isEmpty }
            t.equal(v("Log"), "click 20,20;meter-down;drag 30,30;release 30,30;", "each once, from the skin window")

            // Another skin's window is elsewhere for this skin, and this skin's window for the other one.
            guard let other = app.activate(config: "App\\SliderPlugin", file: nil) else {
                t.check(false, "App\\SliderPlugin loads")
                return
            }
            other.window.setFrame(NSRect(x: 600, y: 400, width: 200, height: 60), display: false)
            t.equal(fake.global.intersection([.otherMouseDown, .otherMouseUp, .otherMouseDragged]),
                    [.otherMouseDown, .otherMouseUp], "the other skin's middle button joins in (drags during its presses)")
            c.skin.setVariable("Log", "")
            fake.pressedButtons = 1
            fake.pointerLocation = NSPoint(x: 650, y: 440)
            if let down = inWindow(.leftMouseDown, other.window, 650, 440) { fake.send(down, local: true) }
            flush()
            t.equal(v("Log"), "click 350,60;", "a press on the other skin's window")
            fake.pointerLocation = NSPoint(x: 700, y: 430)
            waitFor(t, "drag followed") { v("Log").contains("drag") }
            fake.pressedButtons = 0
            waitFor(t, "release followed") { v("Log").contains("release") }
            t.equal(v("Log"), "click 350,60;drag 400,70;release 400,70;")
            t.check(monitor.followed.isEmpty)
            t.equal(v("Order", other), "", "the other skin did not get its own window's press from the monitor")
            // A right press on this skin's window reaches the other skin's right-button measure.
            fake.pressedButtons = 2
            fake.pointerLocation = NSPoint(x: 310, y: 490)
            if let down = inWindow(.rightMouseDown, c.window, 310, 490) { fake.send(down, local: true) }
            fake.pressedButtons = 0
            waitFor(t, "release followed") { monitor.followed.isEmpty && monitor.queue.isEmpty }
            t.equal(v("Order", other), "right-click right-release ", "the other skin's Slider saw it")
            t.equal(v("Right", other), "0", "left of its track: clamped by the skin's own formula")
            t.equal(v("Screen"), "", "not this skin's: its window reports its own presses")
            t.equal(fake.badStops, 0)
            t.equal(fake.overlaps, 0, "no event type watched twice")
        }

        t.suite("App: Plugin=Slider elsewhere on the screen: RelativeToSkin, other screens and the skin's scale") {
            guard let app = try makeApp(t), let c = app.activate(config: "App\\SliderElsewhere", file: nil) else {
                return
            }
            t.atSuiteEnd { app.stopAllForTermination() }
            let monitor = app.outsidePointer
            let fake = FakePointerEventSource()
            monitor.use(fake)
            let primaryHeight = Double(WindowGeometry.primaryHeight(WindowGeometry.currentScreens()))
            func rightClick(_ x: Double, _ y: Double) -> String {
                c.skin.setVariable("Screen", "")
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                                                         pressure: 1) else { continue }
                    fake.send(event, local: false)
                }
                waitFor(t, "input delivered") { monitor.queue.isEmpty }
                return c.skin.variable("Screen") ?? ""
            }
            func screen(_ x: Double, _ y: Double) -> String { "\(Int(x)),\(Int(primaryHeight - y))" }
            // RelativeToSkin=0: screen coordinates from the primary screen's top-left corner, wherever the skin is —
            // here on screens left of and above the primary one, and the click on yet another screen.
            c.window.setFrame(NSRect(x: -1500, y: 200, width: 200, height: 100), display: false)
            t.equal(rightClick(-1450, 250), screen(-1450, 250), "a screen to the left")
            t.equal(rightClick(2500, -300), screen(2500, -300), "a click on a screen right of and below the primary")
            c.window.setFrame(NSRect(x: 100, y: primaryHeight + 300, width: 200, height: 100), display: false)
            t.equal(rightClick(150, primaryHeight + 350), screen(150, primaryHeight + 350),
                    "a skin on a screen above the primary one: negative Y")
            t.check(rightClick(150, primaryHeight + 350).hasSuffix(",-350"))

            // From the skin's corner, in the view's coordinates (as SkinView converts its own events).
            c.skin.setVariable("Log", "")
            for (type, x, y) in [(NSEvent.EventType.leftMouseDown, 90.0, primaryHeight + 380), (.leftMouseUp, 90, 0)] {
                if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    fake.send(event, local: false)
                }
            }
            waitFor(t, "input delivered") { monitor.queue.isEmpty }
            t.equal(c.skin.variable("Log"), "click -10,20;release -10,\(Int(primaryHeight) + 400);")
            let size = c.view.bounds.size
            c.view.setBoundsSize(NSSize(width: size.width / 2, height: size.height / 2))
            let scaled = c.skinPoint(fromScreen: NSPoint(x: 140, y: primaryHeight + 380))
            t.check(scaled.x == 20 && scaled.y == 10, "a scaled view: \(scaled)")
            c.view.setBoundsSize(size)
            let unscaled = c.skinPoint(fromScreen: NSPoint(x: 140, y: primaryHeight + 380))
            t.check(unscaled.x == 40 && unscaled.y == 20, "\(unscaled)")
        }

        t.suite("App: Plugin=Slider's monitors come and go with the measures that need them") {
            guard let app = try makeApp(t) else { return }
            t.atSuiteEnd { app.stopAllForTermination() }
            let monitor = app.outsidePointer
            let fake = FakePointerEventSource()
            monitor.use(fake)
            t.check(!fake.isWatching, "no skin, nothing watched")
            _ = app.activate(config: "App\\MousePlugin", file: nil)
            t.check(!fake.isWatching, "the Mouse plugin (version 3) sees only its skin")
            guard let c = app.activate(config: "App\\SliderElsewhere", file: nil) else {
                t.check(false, "App\\SliderElsewhere loads")
                return
            }
            t.check(fake.isWatching, "loaded")
            t.check(!fake.global.contains(.mouseMoved) && !fake.local.contains(.mouseMoved), "no moves yet")
            func globalEvent(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
                if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                  context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                                                  pressure: type == .mouseMoved ? 0 : 1) {
                    t.check(fake.send(event, local: false), "\(type) watched in other apps")
                }
                waitFor(t, "input delivered") { monitor.queue.isEmpty }
            }
            globalEvent(.leftMouseDown, 10, 10)
            t.equal(monitor.dragMask, .leftMouseDragged, "a left press held in another app: its drags are watched")
            let keys: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
            c.skin.execute("[!EnableMeasure MeasureMoves]", from: nil)
            t.check(fake.global.contains(.mouseMoved) && fake.local.contains(.mouseMoved), "moves for a MoveAction")
            t.equal(fake.global.intersection([.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]),
                    [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged], "a MoveAction runs on every drag")
            t.check(monitor.dragMask.isEmpty && fake.monitors == 1 && fake.overlaps == 0,
                    "no second monitor for the drags the moves' monitor watches")
            t.check(fake.global.intersection(keys).isEmpty && fake.local.intersection(keys).isEmpty, "never keys")

            // Moves: the newest of those waiting together; none from the skin's own window.
            c.window.setFrame(NSRect(x: 300, y: 400, width: 200, height: 100), display: false)
            for x in [10.0, 20, 30] {
                if let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: 450), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    fake.send(event, local: false)
                }
            }
            t.equal(monitor.queue.count, 1, "moves waiting together are one")
            waitFor(t, "input delivered") { monitor.queue.isEmpty }
            t.equal(c.skin.variable("Moved"), "-270,50")
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 60, y: 50), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 0, pressure: 0) {
                fake.send(event, local: true)
            }
            waitFor(t, "input delivered") { monitor.queue.isEmpty }
            t.equal(c.skin.variable("Moved"), "-270,50", "a move in the skin's own window is SkinView's to report")
            // The skin window reported the pointer over the skin, then stopped getting the mouse (hidden, or here never
            // on screen): a move over its area in another app is its input from elsewhere.
            if let event = NSEvent.mouseEvent(with: .mouseMoved,
                                              location: c.window.convertPoint(fromScreen: NSPoint(x: 350, y: 450)),
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 0, pressure: 0) {
                c.view.mouseMoved(with: event)
            }
            waitFor(t, "SkinView reports the move over the skin") { c.skin.variable("Moved") == "50,50" }
            t.check(!c.skinWindowTakesPointer(c.skin), "a window not on screen does not get the mouse")
            globalEvent(.mouseMoved, 360, 440)
            waitFor(t, "so a move over its area elsewhere is its own: \(c.skin.variable("Moved") ?? "")") {
                c.skin.variable("Moved") == "60,60"
            }

            c.skin.execute("[!DisableMeasure MeasureMoves]", from: nil)
            t.check(fake.isWatching && !fake.global.contains(.mouseMoved), "moves no longer watched")
            t.check(monitor.dragMask.isEmpty && monitor.heldElsewhere.isEmpty,
                    "the moves without buttons said the left press was released: no drags watched")
            globalEvent(.leftMouseDown, 10, 10)
            t.equal(monitor.dragMask, .leftMouseDragged)
            c.skin.execute("[!DisableMeasure MeasureClicks][!DisableMeasure MeasureScreen]", from: nil)
            t.check(!fake.isWatching, "all its Slider measures disabled")
            t.check(monitor.dragMask.isEmpty && monitor.heldElsewhere.isEmpty && fake.monitors == 0,
                    "the drags of the press held elsewhere too")
            c.skin.execute("[!EnableMeasure MeasureScreen]", from: nil)
            t.equal(fake.global, [.rightMouseDown, .rightMouseUp], "enabled again: only what it needs")
            let starts = fake.starts
            app.refresh(c)
            guard let refreshed = app.controller(for: "App\\SliderElsewhere"), refreshed !== c else {
                t.check(false, "refreshed")
                return
            }
            t.check(fake.isWatching, "refreshed: the new skin asks again")
            t.equal(fake.global, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp],
                    "with the options of the file")
            t.check(fake.starts > starts)
            guard let other = app.activate(config: "App\\SliderPlugin", file: nil) else {
                t.check(false, "App\\SliderPlugin loads")
                return
            }
            app.deactivate(config: refreshed.config)
            t.check(fake.isWatching, "another skin still asks")
            t.equal(fake.global.intersection([.leftMouseDown, .leftMouseUp]), [], "only what that one needs")
            t.check(fake.global.contains(.rightMouseDown) && fake.global.contains(.otherMouseDown))
            other.skin.execute("[!DisableMeasure MeasureRight]", from: nil)
            t.equal(fake.global, [.otherMouseDown, .otherMouseUp])
            other.skin.execute("[!EnableMeasure MeasureRight]", from: nil)
            app.stopAllForTermination()
            t.check(!fake.isWatching, "quitting stops watching")
            t.equal(fake.badStops, 0, "each monitor removed once")
            t.equal(fake.starts, fake.stops)
            t.equal(fake.overlaps, 0, "no event type watched twice")
            t.check(monitor.followed.isEmpty && monitor.queue.isEmpty)
        }

        t.suite("App: Plugin=Slider's event types are mouse types only, and the monitor maps them") {
            let all = OutsidePointerNeeds(buttons: Set(MouseButton.allCases), dragButtons: Set(MouseButton.allCases),
                                          moves: true)
            let masks = OutsidePointerMonitor.masks(for: all)
            t.equal(masks.global, OutsidePointerMonitor.mouseTypes)
            t.equal(masks.local, [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved])
            t.equal(OutsidePointerMonitor.masks(for: OutsidePointerNeeds()).global, [])
            t.equal(OutsidePointerMonitor.masks(for: OutsidePointerNeeds(buttons: [.middle])).global,
                    [.otherMouseDown, .otherMouseUp])
            // Drag and Hold actions: drags only while a press made elsewhere is held.
            var dragging = OutsidePointerNeeds(buttons: [.left, .middle], dragButtons: [.left, .middle])
            t.equal(OutsidePointerMonitor.masks(for: dragging).global,
                    [.leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp])
            t.equal(OutsidePointerMonitor.dragMask(for: dragging, held: []), [])
            t.equal(OutsidePointerMonitor.dragMask(for: dragging, held: [.left, .right]), .leftMouseDragged)
            t.equal(OutsidePointerMonitor.dragMask(for: dragging, held: [.middle]), .otherMouseDragged)
            dragging.moves = true
            t.equal(OutsidePointerMonitor.dragMask(for: dragging, held: [.left]), [],
                    "a MoveAction watches every drag anyway")
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let expected: [(NSEvent.EventType, PointerEvent)] = [
                (.leftMouseDown, .pressed(.left, doubleClick: false)), (.rightMouseDown, .pressed(.right, doubleClick: false)),
                (.leftMouseUp, .released(.left)), (.rightMouseUp, .released(.right)), (.leftMouseDragged, .dragged),
                (.rightMouseDragged, .dragged), (.otherMouseDragged, .dragged), (.mouseMoved, .moved),
            ]
            for (type, pointer) in expected {
                t.equal(event(type).flatMap(OutsidePointerMonitor.pointerEvent(for:)), pointer, "\(type)")
            }
            // Synthesized "other" button events are button 0; a CGEvent sets the middle button.
            if let cg = event(.otherMouseDown)?.cgEvent {
                cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                t.equal(NSEvent(cgEvent: cg).flatMap(OutsidePointerMonitor.pointerEvent(for:)),
                        .pressed(.middle, doubleClick: false))
                cg.setIntegerValueField(.mouseEventButtonNumber, value: 7)
                t.equal(NSEvent(cgEvent: cg).flatMap(OutsidePointerMonitor.pointerEvent(for:)), nil, "button 7")
            }
            t.equal(event(.otherMouseDown).flatMap(OutsidePointerMonitor.pointerEvent(for:)), nil,
                    "an other-button event claiming button 0")
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                       isARepeat: false, keyCode: 0)
            t.equal(key.flatMap(OutsidePointerMonitor.pointerEvent(for:)), nil, "keys are nothing")
        }
    }

    /// Runs the main run loop until `condition` holds, and checks that it did (`what`). Input goes through a turn of
    /// the run loop, and follows and moves through the monitor's and the Slider's 20 ms timers, which a busy CI
    /// machine fires late or stalls for seconds: a minute, so the limit only tells "late" from "never", and a run
    /// that never gets there says what it waited for.
    private static func waitFor(_ t: AppTestRunner, _ what: @autoclosure () -> String, line: UInt = #line,
                                _ condition: () -> Bool) {
        t.check(spin(timeout: 60, until: condition), what(), line: line)
    }
}
