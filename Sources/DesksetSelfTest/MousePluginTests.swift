import Foundation
@testable import DesksetCore

// Plugin=Mouse (suite prefix "Plugin: Mouse"). The skin gets its mouse input through `Skin.pointerEvent` as the app
// reports it; the actions log into skin variables. Deterministic: UpdateRate=0 or a fake clock (one test waits for
// the end of an UpdateRate interval on the main run loop).

func runMousePluginTests(_ t: TestRunner) {
    CorePlugins.register()
    runMouseRegistrationTests(t)
    runMouseActionTests(t)
    runMouseCoordinateTests(t)
    runMouseRequireDraggingTests(t)
    runMouseStateTests(t)
    runMouseUpdateRateTests(t)
}

// MARK: - Helpers

/// A host whose skin window sits at (100, 200) on the screen.
private final class FramedHost: FakeHost {
    override func environment(for skin: Skin) -> SkinEnvironment {
        SkinEnvironment(windowFrame: SkinRect(x: 100, y: 200, width: skin.width, height: skin.height))
    }
}

/// A 100×50 skin with the given sections (and `[Variables]` lines), updated once.
private func mouseSkin(_ t: TestRunner, _ sections: String, variables: String = "",
                       host: FakeHost = FakeHost()) throws -> Skin {
    let ini = """
    [Rainmeter]
    Update=-1

    [Variables]
    Log=
    \(variables)

    \(sections)

    [Box]
    Meter=Image
    W=100
    H=50
    SolidColor=0,0,0,255
    """
    let (skin, _) = try makeSkin(t, ini, host: host)
    skin.update()
    return skin
}

/// The actions of the test skins append to the variable Log.
private func appending(_ text: String) -> String { "[!SetVariable Log \"[#Log]\(text);\"]" }

private func log(_ skin: Skin) -> String { skin.variable("Log") ?? "" }

private func clearLog(_ skin: Skin) { skin.setVariable("Log", "") }

/// Spins the main run loop until `condition` holds, for at most `timeout` seconds; false if it never did. The limit
/// only tells "late" from "never": a slow or busy machine fires a 15 ms timer 100 ms or more late (CI's Intel runner,
/// and `taskpolicy -b`, which coalesces timers).
@discardableResult
private func spinMainRunLoop(until condition: () -> Bool, timeout: TimeInterval = 60) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

// MARK: - Registration

private func runMouseRegistrationTests(_ t: TestRunner) {
    t.suite("Plugin: Mouse is registered and reads 0") {
        t.check(MeasureRegistry.plugin(named: "Mouse") == MouseMeasure.self)
        t.check(MeasureRegistry.plugin(named: "Plugins\\Mouse.dll") == MouseMeasure.self)
        let (skin, host) = try makeSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseUpAction=[!SetVariable Up 1]

        [Old]
        Measure=Plugin
        Plugin=Plugins\\Mouse.dll

        [T]
        Meter=String
        MeasureName=M
        """)
        skin.update()
        t.equal(skin.issues, [], "no compatibility issue")
        t.check(skin.measure(named: "M") is MouseMeasure)
        t.check(skin.measure(named: "Old") is MouseMeasure)
        t.equal(skin.measure(named: "M")?.value, 0)
        t.equal(text(skin, "T"), "0")
        skin.execute("[!CommandMeasure M \"Bogus\"]", from: nil)
        t.check(host.logs.contains { $0.contains("not supported") && $0.contains("[M]") },
                "unknown commands are logged")
    }

    t.suite("Plugin: Mouse input does not reach meters or skins without the plugin") {
        let skin = try mouseSkin(t, """
        [Hit]
        Meter=Image
        W=10
        H=10
        SolidColor=255,0,0,255
        LeftMouseDownAction=\(appending("meter"))
        """)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 5, y: 5)
        skin.pointerEvent(.released(.left), x: 5, y: 5)
        t.equal(log(skin), "", "pointer input is only for Plugin=Mouse measures")
        skin.mouseEvent(.leftDown, x: 5, y: 5)
        t.equal(log(skin), "meter;", "meter actions come from mouseEvent")
    }
}

// MARK: - Actions

private func runMouseActionTests(_ t: TestRunner) {
    t.suite("Plugin: Mouse runs every documented action with $MouseX$ / $MouseY$") {
        let skin = try mouseSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDownAction=\(appending("down $MouseX$,$MouseY$"))
        LeftMouseUpAction=\(appending("up $MouseX$,$MouseY$"))
        LeftMouseDoubleClickAction=\(appending("double $mousex$,$mousey$"))
        LeftMouseDragAction=\(appending("drag $MouseX$,$MouseY$"))
        RightMouseDownAction=\(appending("rdown"))
        RightMouseUpAction=\(appending("rup"))
        RightMouseDragAction=\(appending("rdrag"))
        MiddleMouseDownAction=\(appending("mdown"))
        MiddleMouseDragAction=\(appending("mdrag"))
        X1MouseUpAction=\(appending("x1up"))
        X2MouseDownAction=\(appending("x2down"))
        X2MouseDoubleClickAction=\(appending("x2double"))
        MouseScrollUpAction=\(appending("wheelup $MouseX$"))
        MouseScrollRightAction=\(appending("wheelright"))
        MouseOverAction=\(appending("over"))
        MouseLeaveAction=\(appending("leave"))
        MouseMoveAction=\(appending("move $MouseX$,$MouseY$"))
        UpdateRate=0
        """)
        skin.pointerEvent(.moved, x: 10, y: 20)
        t.equal(log(skin), "over;move 10,20;", "the pointer comes over the skin, then moves")
        clearLog(skin)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10.7, y: 20.2)
        t.equal(log(skin), "down 10,20;", "whole points, rounded down like $MouseX$ of meters")
        clearLog(skin)
        skin.pointerEvent(.dragged, x: 30, y: 40)
        t.equal(log(skin), "move 30,40;drag 30,40;", "MouseMoveAction first, then the drag action")
        clearLog(skin)
        skin.pointerEvent(.dragged, x: -5, y: 70)
        t.equal(log(skin), "leave;move -5,70;drag -5,70;", "a press is followed outside the skin")
        clearLog(skin)
        skin.pointerEvent(.released(.left), x: -5, y: 70)
        t.equal(log(skin), "up -5,70;", "…and so is its release")
        clearLog(skin)
        skin.pointerEvent(.released(.left), x: 1, y: 1)
        t.equal(log(skin), "", "no release without a press")
        skin.pointerEvent(.pressed(.left, doubleClick: true), x: 5, y: 6)
        t.equal(log(skin), "over;double 5,6;down 5,6;", "a double click runs both actions (manual)")
        skin.pointerEvent(.released(.left), x: 5, y: 6)
        clearLog(skin)

        skin.pointerEvent(.pressed(.right, doubleClick: false), x: 1, y: 1)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 1, y: 1)
        skin.pointerEvent(.dragged, x: 2, y: 2)
        t.equal(log(skin), "rdown;down 1,1;move 2,2;drag 2,2;rdrag;", "every held button drags, left to X2")
        clearLog(skin)
        skin.pointerEvent(.released(.right), x: 2, y: 2)
        skin.pointerEvent(.dragged, x: 3, y: 3)
        skin.pointerEvent(.released(.left), x: 3, y: 3)
        t.equal(log(skin), "rup;move 3,3;drag 3,3;up 3,3;")
        clearLog(skin)
        skin.pointerEvent(.pressed(.middle, doubleClick: false), x: 4, y: 4)
        skin.pointerEvent(.dragged, x: 4, y: 5)
        skin.pointerEvent(.released(.middle), x: 4, y: 5)
        skin.pointerEvent(.pressed(.x1, doubleClick: false), x: 4, y: 5)
        skin.pointerEvent(.released(.x1), x: 4, y: 5)
        skin.pointerEvent(.pressed(.x2, doubleClick: true), x: 4, y: 5)
        skin.pointerEvent(.released(.x2), x: 4, y: 5)
        t.equal(log(skin), "mdown;move 4,5;mdrag;x1up;x2double;x2down;", "middle and side buttons")
        clearLog(skin)
        skin.pointerEvent(.scrolled(.scrollUp), x: 7, y: 8)
        skin.pointerEvent(.scrolled(.scrollDown), x: 7, y: 8)
        skin.pointerEvent(.scrolled(.scrollRight), x: 7, y: 8)
        t.equal(log(skin), "wheelup 7;wheelright;", "one action per wheel notch; no action when none is set")
        clearLog(skin)
        skin.pointerEvent(.exited, x: 120, y: 8)
        t.equal(log(skin), "leave;")
        skin.pointerEvent(.exited, x: 120, y: 8)
        t.equal(log(skin), "leave;", "left once")
    }

    t.suite("Plugin: Mouse drags only presses made on the skin") {
        let skin = try mouseSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseUpAction=\(appending("up $MouseX$"))
        LeftMouseDragAction=\(appending("drag"))
        MouseMoveAction=\(appending("move $MouseX$"))
        UpdateRate=0
        """)
        skin.pointerEvent(.dragged, x: 10, y: 10)
        t.equal(log(skin), "move 10;", "a press that started elsewhere moves the pointer, it is no drag")
        skin.pointerEvent(.released(.left), x: 10, y: 10)
        t.equal(log(skin), "move 10;", "…and its release is not this skin's")
        clearLog(skin)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.moved, x: 12, y: 12)
        t.equal(log(skin), "up 12;move 12;", "a release that never arrived is reported with the next move")
        clearLog(skin)
        skin.pointerEvent(.dragged, x: 13, y: 13)
        t.equal(log(skin), "move 13;", "the button no longer drags")
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.exited, x: 150, y: 10)
        clearLog(skin)
        skin.pointerEvent(.dragged, x: 150, y: 10)
        t.equal(log(skin), "move 150;drag;", "leaving the window during a press does not end it")
    }

    t.suite("Plugin: Mouse measures get the input in file order, and nothing once the skin closed") {
        let skin = try mouseSkin(t, """
        [A]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDownAction=\(appending("A"))
        MouseMoveAction=[!DisableMeasure A]
        LeftMouseDragAction=\(appending("A drag"))
        UpdateRate=0

        [B]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDownAction=\(appending("B"))
        LeftMouseDragAction=\(appending("B drag"))
        MoveAction=\(appending("B moveaction"))
        UpdateRate=0
        """)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 1, y: 1)
        t.equal(log(skin), "A;B;")
        clearLog(skin)
        skin.pointerEvent(.dragged, x: 2, y: 2)
        t.equal(log(skin), "B moveaction;B drag;",
                "an action that disables its measure ends that measure's part of the event; MoveAction of version 3.0")
        skin.close()
        clearLog(skin)
        skin.pointerEvent(.dragged, x: 3, y: 3)
        skin.pointerEvent(.released(.left), x: 3, y: 3)
        t.equal(log(skin), "", "a closed skin runs nothing")
    }
}

// MARK: - Coordinates

private func runMouseCoordinateTests(_ t: TestRunner) {
    t.suite("Plugin: Mouse RelativeToSkin=0 gives screen coordinates; only $MouseX$ / $MouseY$ are replaced") {
        let skin = try mouseSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDownAction=[!SetVariable P "$MouseX$ $MouseY$ $MouseX:%$ $MouseY:%$"]
        RelativeToSkin=#Rel#
        DynamicVariables=1

        [Meter]
        Meter=Image
        X=50
        W=50
        H=50
        SolidColor=0,0,0,255
        RightMouseDownAction=[!SetVariable Q "$MouseX$ $MouseX:%$"]
        """, variables: "Rel=1", host: FramedHost())
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 20)
        t.equal(skin.variable("P"), "10 20 $MouseX:%$ $MouseY:%$", "RelativeToSkin=1 (default): from the skin's corner")
        skin.pointerEvent(.released(.left), x: 10, y: 20)
        skin.setVariable("Rel", "0")
        skin.execute("[!UpdateMeasure M]", from: nil)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 20)
        t.equal(skin.variable("P"), "110 220 $MouseX:%$ $MouseY:%$", "RelativeToSkin=0: from the screen's corner")
        skin.pointerEvent(.released(.left), x: 10, y: 20)
        skin.mouseEvent(.rightDown, x: 75, y: 5)
        t.equal(skin.variable("Q"), "25 50", "meter actions keep their meter-relative variables and the % forms")
    }
}

// MARK: - RequireDragging

private func runMouseRequireDraggingTests(_ t: TestRunner) {
    t.suite("Plugin: Mouse RequireDragging=1 runs actions only between Start and Stop") {
        // Two sliders, each started by its own knob (the pattern of the plugin's example skin and published skins).
        let skin = try mouseSkin(t, """
        [MouseA]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDragAction=[!SetVariable A "(Clamp($MouseX$,0,100))"]
        LeftMouseUpAction=!CommandMeasure MouseA Stop
        RequireDragging=1
        UpdateRate=0

        [MouseB]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDragAction=[!SetVariable B "$MouseX$"]
        LeftMouseUpAction=[!CommandMeasure MouseB "Stop"]
        RequireDragging=1
        UpdateRate=0
        """)
        skin.setVariable("A", "none")
        skin.setVariable("B", "none")
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 5, y: 5)
        skin.pointerEvent(.dragged, x: 20, y: 5)
        t.equal(skin.variable("A"), "none", "not started: no actions")
        skin.pointerEvent(.released(.left), x: 20, y: 5)
        // A knob's LeftMouseDownAction starts its measure.
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 5, y: 5)
        skin.execute("[!CommandMeasure MouseA \"Start\"]", from: nil)
        t.check((skin.measure(named: "MouseA") as? MouseMeasure)?.isStarted == true)
        skin.pointerEvent(.dragged, x: 30, y: 5)
        t.equal(skin.variable("A"), "30")
        skin.pointerEvent(.dragged, x: 250, y: 5)
        t.equal(skin.variable("A"), "100", "dragging goes on outside the skin")
        t.equal(skin.variable("B"), "none", "the other slider was not started")
        skin.pointerEvent(.released(.left), x: 250, y: 5)
        t.check((skin.measure(named: "MouseA") as? MouseMeasure)?.isStarted == false,
                "its LeftMouseUpAction stopped it (old single-bang form)")
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 5, y: 5)
        skin.pointerEvent(.dragged, x: 40, y: 5)
        t.equal(skin.variable("A"), "100", "stopped: no actions")
        skin.pointerEvent(.released(.left), x: 40, y: 5)
    }

    t.suite("Plugin: Mouse Start / Stop need RequireDragging=1 and work while disabled") {
        let (skin, host) = try makeSkin(t, """
        [Free]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDownAction=[!SetVariable Free 1]

        [Later]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDownAction=[!SetVariable Later 1]
        RequireDragging=1
        Disabled=1

        [Box]
        Meter=Image
        W=10
        H=10
        """)
        skin.update()
        skin.execute("[!CommandMeasure Free Stop]", from: nil)
        t.check(host.logs.contains { $0.contains("needs RequireDragging=1") }, "ignored with a warning")
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 1, y: 1)
        skin.pointerEvent(.released(.left), x: 1, y: 1)
        t.equal(skin.variable("Free"), "1", "without RequireDragging the measure is always on")
        t.equal(skin.variable("Later"), nil)
        // Started while disabled (before its options were ever read), then enabled.
        skin.execute("[!CommandMeasure Later Start][!EnableMeasure Later]", from: nil)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 1, y: 1)
        t.equal(skin.variable("Later"), "1")
    }
}

// MARK: - Disabled / paused

private func runMouseStateTests(_ t: TestRunner) {
    t.suite("Plugin: Mouse disabled or paused runs nothing; enabling works at once") {
        let skin = try mouseSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDownAction=\(appending("down"))
        LeftMouseDragAction=\(appending("drag $MouseX$"))
        LeftMouseUpAction=\(appending("up"))
        Disabled=1
        DynamicVariables=1
        UpdateRate=0
        """)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 1, y: 1)
        skin.pointerEvent(.dragged, x: 2, y: 1)
        t.equal(log(skin), "", "Disabled=1")
        // A slider's LeftMouseDownAction enables the measure in the middle of the press (without !UpdateMeasure).
        skin.execute("[!EnableMeasure M]", from: nil)
        skin.pointerEvent(.dragged, x: 3, y: 1)
        skin.pointerEvent(.released(.left), x: 3, y: 1)
        t.equal(log(skin), "drag 3;up;", "the press made while disabled still drags")
        clearLog(skin)
        skin.execute("[!DisableMeasure M]", from: nil)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 1, y: 1)
        skin.pointerEvent(.released(.left), x: 1, y: 1)
        t.equal(log(skin), "", "!DisableMeasure stops it at once")
        skin.execute("[!EnableMeasure M][!PauseMeasure M]", from: nil)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 1, y: 1)
        skin.pointerEvent(.released(.left), x: 1, y: 1)
        t.equal(log(skin), "", "paused")
        skin.execute("[!UnpauseMeasure M][!UpdateMeasure M]", from: nil)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 1, y: 1)
        t.equal(log(skin), "down;", "the documented way (update after the bang) works too")
        skin.execute("[!SetOption M LeftMouseUpAction \"[!SetVariable Changed 1]\"]", from: nil)
        skin.pointerEvent(.released(.left), x: 1, y: 1)
        t.equal(log(skin), "down;", "the old LeftMouseUpAction is gone")
        t.equal(skin.variable("Changed"), "1", "a changed action is read before the next input")
    }
}

// MARK: - UpdateRate

private func runMouseUpdateRateTests(_ t: TestRunner) {
    t.suite("Plugin: Mouse UpdateRate limits move and drag actions and keeps the last position") {
        let skin = try mouseSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Mouse
        MouseMoveAction=\(appending("$MouseX$"))
        LeftMouseDragAction=\(appending("d$MouseX$"))
        LeftMouseUpAction=\(appending("up"))
        """)
        guard let mouse = skin.measure(named: "M") as? MouseMeasure else {
            t.check(false, "Mouse measure")
            return
        }
        var now = 100.0
        mouse.clock = { now }
        skin.pointerEvent(.moved, x: 1, y: 1)
        now += 0.005
        skin.pointerEvent(.moved, x: 2, y: 1)
        now += 0.005
        skin.pointerEvent(.moved, x: 3, y: 1)
        t.equal(log(skin), "1;", "the default UpdateRate is 20 ms")
        now = 100.030
        skin.pointerEvent(.moved, x: 4, y: 1)
        t.equal(log(skin), "1;4;", "the newest position after the interval; older waiting ones are dropped")
        clearLog(skin)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 4, y: 1)
        now += 0.002
        skin.pointerEvent(.dragged, x: 5, y: 1)
        t.equal(log(skin), "", "too soon: waits")
        skin.pointerEvent(.released(.left), x: 5, y: 1)
        t.equal(log(skin), "5;d5;up;", "the release comes after the last drag position")
        clearLog(skin)
        now += 1
        skin.pointerEvent(.moved, x: 6, y: 1)
        now += 0.005
        skin.pointerEvent(.moved, x: 7, y: 1)
        t.equal(log(skin), "6;")
        // The interval's real timer (15 ms) runs the waiting move, whenever the machine gets to fire it.
        t.check(spinMainRunLoop(until: { !mouse.hasPendingMove }), "the waiting move's timer fired")
        t.equal(log(skin), "6;7;", "the waiting position runs when the interval ends")
        now += 0.001
        skin.pointerEvent(.moved, x: 8, y: 1)
        skin.execute("[!DisableMeasure M]", from: nil)
        // Disabling leaves the move waiting; its timer (19 ms) finds the measure disabled and drops it.
        t.check(spinMainRunLoop(until: { !mouse.hasPendingMove }), "the waiting move's timer fired while disabled")
        t.equal(log(skin), "6;7;", "a disabled measure drops the waiting position")

        skin.execute("[!EnableMeasure M][!SetOption M UpdateRate 0][!UpdateMeasure M]", from: nil)
        clearLog(skin)
        skin.pointerEvent(.moved, x: 9, y: 1)
        skin.pointerEvent(.moved, x: 10, y: 1)
        t.equal(log(skin), "9;10;", "UpdateRate=0: every move")
    }
}
