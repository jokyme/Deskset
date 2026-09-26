import Foundation
@testable import DesksetCore

// Plugin=Slider (suite prefix "Plugin: Slider"), version 2 of the Mouse plugin. The skin gets its mouse input through
// `Skin.pointerEvent` as the app reports it; the actions log into skin variables. Moves use fake clocks (the plugin
// runs move and drag actions at most every 20 ms); the hold tests wait for the hold timer on the main run loop.

func runSliderPluginTests(_ t: TestRunner) {
    CorePlugins.register()
    runSliderRegistrationTests(t)
    runSliderActionTests(t)
    runSliderHoldTests(t)
    runSliderCoordinateTests(t)
    runSliderSkinPatternTests(t)
    runSliderOutsideTests(t)
}

// MARK: - Helpers

/// A host whose skin window sits at (100, 200) on the screen and goes where `!Move` puts it.
private final class MovableHost: FakeHost {
    var origin = (x: 100.0, y: 200.0)

    override func environment(for skin: Skin) -> SkinEnvironment {
        SkinEnvironment(windowFrame: SkinRect(x: origin.x, y: origin.y, width: skin.width, height: skin.height))
    }

    override func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        if bang.name == "move", bang.args.count >= 2, let x = OptionValue.number(bang.args[0]),
           let y = OptionValue.number(bang.args[1]) {
            origin = (x, y)
        }
        return super.skin(skin, handle: bang)
    }
}

/// A 100×50 skin with the given sections (and `[Variables]` lines), updated once. Its Slider measures get clocks
/// that move on by a second at every reading, so no move waits for the 20 ms interval (a test may set its own).
private func sliderSkin(_ t: TestRunner, _ sections: String, variables: String = "", files: [String: String] = [:],
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
    let (skin, _) = try makeSkin(t, ini, files: files, host: host)
    for case let slider as SliderMeasure in skin.measures {
        var now = 0.0
        slider.clock = {
            now += 1
            return now
        }
    }
    skin.update()
    return skin
}

/// The actions of the test skins append to the variable Log.
private func appending(_ text: String) -> String { "[!SetVariable Log \"[#Log]\(text);\"]" }

private func log(_ skin: Skin) -> String { skin.variable("Log") ?? "" }

private func clearLog(_ skin: Skin) { skin.setVariable("Log", "") }

/// Spins the main run loop until `condition` holds, for at most `timeout` seconds; false if it never did. A minute by
/// default: the hold and move timers are real, and a slow or busy machine fires them late or stalls for seconds (CI);
/// the limit only tells "late" from "never".
@discardableResult
private func spin(until condition: () -> Bool, timeout: TimeInterval = 60) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

private func spin(for seconds: TimeInterval) { spin(until: { false }, timeout: seconds) }

// MARK: - Registration

private func runSliderRegistrationTests(_ t: TestRunner) {
    t.suite("Plugin: Slider is registered, reads 0 and has no commands") {
        t.check(MeasureRegistry.plugin(named: "Slider") == SliderMeasure.self)
        t.check(MeasureRegistry.plugin(named: "Slider.dll") == SliderMeasure.self)
        t.check(MeasureRegistry.plugin(named: "Plugins\\Slider.dll") == SliderMeasure.self)
        let (skin, host) = try makeSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Slider.dll
        ClickAction=[!SetVariable Clicked 1]

        [Short]
        Measure=Plugin
        Plugin=Slider

        [T]
        Meter=String
        MeasureName=M
        """)
        skin.update()
        t.equal(skin.issues, [], "no compatibility issue")
        t.check(skin.measure(named: "M") is SliderMeasure)
        t.check(skin.measure(named: "Short") is SliderMeasure)
        t.equal(skin.measure(named: "M")?.value, 0)
        t.equal(text(skin, "T"), "0")
        skin.execute("[!CommandMeasure M \"Start\"]", from: nil)
        t.check(host.logs.contains { $0.contains("not supported") && $0.contains("[M]") },
                "Start is version 3's (RequireDragging)")
        t.check(!host.logs.contains { $0.contains("RequireDragging") })
    }
}

// MARK: - Actions

private func runSliderActionTests(_ t: TestRunner) {
    t.suite("Plugin: Slider runs ClickAction, DragAction, ReleaseAction and MoveAction with $MouseX$ / $MouseY$") {
        let skin = try sliderSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Slider.dll
        ClickAction=\(appending("click $MouseX$,$MouseY$"))
        DragAction=\(appending("drag $mouseX$,$mouseY$"))
        ReleaseAction=\(appending("release $MOUSEX$,$MOUSEY$"))
        MoveAction=\(appending("move $MouseX$,$MouseY$"))
        """)
        skin.pointerEvent(.moved, x: 10, y: 20)
        t.equal(log(skin), "move 10,20;", "the pointer moves over the skin (version 2 has no hover actions)")
        clearLog(skin)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10.7, y: 20.2)
        t.equal(log(skin), "click 10,20;", "whole points; the variables in any case (version 2.2.2.41)")
        clearLog(skin)
        skin.pointerEvent(.dragged, x: 30, y: 40)
        t.equal(log(skin), "move 30,40;drag 30,40;", "MoveAction first, then DragAction")
        clearLog(skin)
        skin.pointerEvent(.dragged, x: -5, y: 70)
        skin.pointerEvent(.released(.left), x: -5, y: 70)
        t.equal(log(skin), "move -5,70;drag -5,70;release -5,70;", "a press is followed outside the skin")
        clearLog(skin)
        skin.pointerEvent(.pressed(.left, doubleClick: true), x: 5, y: 6)
        t.equal(log(skin), "click 5,6;", "a double click is one more press")
        skin.pointerEvent(.released(.left), x: 5, y: 6)
        clearLog(skin)

        skin.pointerEvent(.pressed(.right, doubleClick: false), x: 7, y: 8)
        skin.pointerEvent(.dragged, x: 8, y: 8)
        skin.pointerEvent(.released(.right), x: 8, y: 8)
        skin.pointerEvent(.scrolled(.scrollUp), x: 8, y: 8)
        skin.pointerEvent(.exited, x: 120, y: 8)
        t.equal(log(skin), "move 8,8;", "another button only moves the pointer; wheel and leaving run nothing")
        clearLog(skin)
        skin.pointerEvent(.dragged, x: 10, y: 10)
        skin.pointerEvent(.released(.left), x: 10, y: 10)
        t.equal(log(skin), "move 10,10;", "a press that started elsewhere is no drag, and its release not this skin's")
        clearLog(skin)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.moved, x: 12, y: 12)
        t.equal(log(skin), "click 10,10;release 12,12;move 12,12;",
                "a release that never arrived is reported with the next move")
    }

    t.suite("Plugin: Slider MouseButton picks the button") {
        let (skin, host) = try makeSkin(t, """
        [Rainmeter]
        Update=-1

        [Variables]
        Log=

        [L]
        Measure=Plugin
        Plugin=Slider
        MouseButton=Left
        ClickAction=\(appending("L click"))
        DragAction=\(appending("L drag"))
        ReleaseAction=\(appending("L release"))

        [R]
        Measure=Plugin
        Plugin=Slider
        MouseButton=right
        ClickAction=\(appending("R click $MouseX$"))
        DragAction=\(appending("R drag $MouseX$"))
        ReleaseAction=\(appending("R release $MouseX$"))

        [Mid]
        Measure=Plugin
        Plugin=Slider
        MouseButton= Middle
        ClickAction=\(appending("Mid click"))
        DragAction=\(appending("Mid drag"))
        ReleaseAction=\(appending("Mid release"))

        [Bad]
        Measure=Plugin
        Plugin=Slider
        MouseButton=X1
        ClickAction=\(appending("Bad click"))

        [Box]
        Meter=Image
        W=100
        H=50
        """)
        skin.update()
        func button(_ name: String) -> MouseButton? { (skin.measure(named: name) as? SliderMeasure)?.button }
        t.equal(button("L"), .left)
        t.equal(button("R"), .right, "any case")
        t.equal(button("Mid"), .middle)
        t.equal(button("Bad"), .left, "anything else is the left button…")
        t.check(host.logs.contains { $0.contains("MouseButton=X1 is not Left, Right or Middle") }, "…with a warning")

        skin.pointerEvent(.pressed(.right, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.dragged, x: 20, y: 10)
        skin.pointerEvent(.released(.right), x: 30, y: 10)
        t.equal(log(skin), "R click 10;R drag 20;R release 30;")
        clearLog(skin)
        skin.pointerEvent(.pressed(.middle, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.dragged, x: 20, y: 10)
        skin.pointerEvent(.released(.middle), x: 20, y: 10)
        t.equal(log(skin), "Mid click;Mid drag;Mid release;")
        clearLog(skin)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.pressed(.x1, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.released(.x1), x: 10, y: 10)
        skin.pointerEvent(.released(.left), x: 10, y: 10)
        t.equal(log(skin), "L click;Bad click;L release;", "in file order; the side buttons are nobody's")
    }

    t.suite("Plugin: Slider runs move and drag actions at most every 20 ms and reads only version 2's options") {
        let skin = try sliderSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Slider
        MoveAction=\(appending("$MouseX$"))
        DragAction=\(appending("d$MouseX$"))
        ReleaseAction=\(appending("up"))
        UpdateRate=0
        RequireDragging=1
        LeftMouseDownAction=\(appending("v3 down"))
        MouseMoveAction=\(appending("v3 move"))
        LeftMouseDragAction=\(appending("v3 drag"))
        MouseOverAction=\(appending("v3 over"))

        [Mouse]
        Measure=Plugin
        Plugin=Mouse
        ClickAction=\(appending("v2 click"))
        UpdateRate=0
        """)
        guard let slider = skin.measure(named: "M") as? SliderMeasure else {
            t.check(false, "Slider measure")
            return
        }
        var now = 100.0
        slider.clock = { now }
        skin.pointerEvent(.moved, x: 1, y: 1)
        now += 0.005
        skin.pointerEvent(.moved, x: 2, y: 1)
        now += 0.005
        skin.pointerEvent(.moved, x: 3, y: 1)
        t.equal(log(skin), "1;", "20 ms, whatever UpdateRate says (a version 3 option)")
        now = 100.030
        skin.pointerEvent(.moved, x: 4, y: 1)
        t.equal(log(skin), "1;4;", "the newest position after the interval")
        clearLog(skin)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 4, y: 1)
        now += 0.002
        skin.pointerEvent(.dragged, x: 5, y: 1)
        t.equal(log(skin), "", "too soon: waits; no version 3 action, no ClickAction on the Mouse measure")
        skin.pointerEvent(.released(.left), x: 5, y: 1)
        t.equal(log(skin), "5;d5;up;", "the release comes after the last drag position; RequireDragging is ignored")
    }
}

// MARK: - HoldAction

private func runSliderHoldTests(_ t: TestRunner) {
    t.suite("Plugin: Slider HoldAction runs once when the button is still down after HoldDelay") {
        let skin = try sliderSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Slider
        ClickAction=\(appending("click"))
        DragAction=\(appending("drag $MouseX$"))
        HoldAction=\(appending("hold $MouseX$,$MouseY$"))
        ReleaseAction=\(appending("release"))
        HoldDelay=#Delay#
        DynamicVariables=1

        [Plain]
        Measure=Plugin
        Plugin=Slider
        """, variables: "Delay=20")
        guard let slider = skin.measure(named: "M") as? SliderMeasure,
              let plain = skin.measure(named: "Plain") as? SliderMeasure else {
            t.check(false, "Slider measures")
            return
        }
        t.equal(slider.holdDelay, 0.02)
        t.equal(plain.holdDelay, 0.3, "HoldDelay defaults to 300 ms")
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.dragged, x: 40, y: 15)
        t.equal(log(skin), "click;drag 40;", "not held long enough yet")
        t.check(spin(until: { log(skin).contains("hold") }), "held")
        t.equal(log(skin), "click;drag 40;hold 40,15;", "where the pointer is when the delay ends")
        spin(for: 0.1)
        skin.pointerEvent(.released(.left), x: 40, y: 15)
        t.equal(log(skin), "click;drag 40;hold 40,15;release;", "once per press")

        clearLog(skin)
        skin.setVariable("Delay", "60")
        skin.execute("[!UpdateMeasure M]", from: nil)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.released(.left), x: 10, y: 10)
        spin(for: 0.2)
        t.equal(log(skin), "click;release;", "a release before the delay ends the hold")

        for (option, seconds) in [("-5", 0.0), ("abc", 0.3), ("(1000/4)", 0.25)] {
            skin.setVariable("Delay", option)
            skin.execute("[!UpdateMeasure M]", from: nil)
            t.equal(slider.holdDelay, seconds, "HoldDelay=\(option)")
        }
    }

    t.suite("Plugin: Slider holds only its button's presses, and not while disabled or after the skin closed") {
        let skin = try sliderSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Slider
        DragAction=\(appending("drag $MouseX$"))
        HoldAction=\(appending("hold $MouseX$"))
        HoldDelay=0
        """)
        guard let slider = skin.measure(named: "M") as? SliderMeasure else {
            t.check(false, "Slider measure")
            return
        }
        skin.pointerEvent(.pressed(.right, doubleClick: false), x: 10, y: 10)
        spin(for: 0.05)
        skin.pointerEvent(.released(.right), x: 10, y: 10)
        t.equal(log(skin), "", "the right button is not tracked")
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.execute("[!DisableMeasure M]", from: nil)
        // Disabling leaves the hold waiting: its timer finds the measure disabled.
        t.check(spin(until: { !slider.isHoldWaiting }), "the delay ended")
        skin.pointerEvent(.released(.left), x: 10, y: 10)
        t.equal(log(skin), "", "disabled when the delay ends")
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 11, y: 10)
        skin.execute("[!EnableMeasure M]", from: nil)
        t.check(spin(until: { !log(skin).isEmpty }), "held")
        t.equal(log(skin), "hold 11;", "a press made while disabled holds once the measure is enabled, as it drags")
        skin.pointerEvent(.released(.left), x: 11, y: 10)
        clearLog(skin)

        // The drag position waiting for the end of its 20 ms runs before the hold.
        var now = 100.0
        slider.clock = { now }
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.pointerEvent(.dragged, x: 20, y: 10)
        now += 0.005
        skin.pointerEvent(.dragged, x: 30, y: 10)
        t.equal(log(skin), "drag 20;")
        t.check(spin(until: { log(skin).contains("hold") }), "held")
        t.equal(log(skin), "drag 20;drag 30;hold 30;")
        skin.pointerEvent(.released(.left), x: 30, y: 10)
        clearLog(skin)

        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.close()
        spin(for: 0.05)
        t.equal(log(skin), "", "a closed skin holds nothing")
    }
}

// MARK: - Coordinates

private func runSliderCoordinateTests(_ t: TestRunner) {
    t.suite("Plugin: Slider RelativeToSkin=0 gives screen coordinates, also to the hold") {
        let skin = try sliderSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Slider
        ClickAction=[!SetVariable P "$MouseX$ $MouseY$ $MouseX:%$"]
        HoldAction=[!SetVariable H "$MouseX$ $MouseY$"]
        HoldDelay=0
        RelativeToSkin=#Rel#
        DynamicVariables=1
        """, variables: "Rel=1", host: MovableHost())
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 20)
        t.equal(skin.variable("P"), "10 20 $MouseX:%$", "RelativeToSkin=1 (default): from the skin's corner")
        t.check(spin(until: { skin.variable("H") != nil }), "held")
        t.equal(skin.variable("H"), "10 20")
        skin.pointerEvent(.released(.left), x: 10, y: 20)
        skin.setVariable("Rel", "0")
        skin.execute("[!UpdateMeasure M]", from: nil)
        skin.setVariable("H", "")
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 20)
        t.equal(skin.variable("P"), "110 220 $MouseX:%$", "RelativeToSkin=0: from the screen's corner")
        t.check(spin(until: { skin.variable("H") != "" }), "held")
        t.equal(skin.variable("H"), "110 220")
        skin.pointerEvent(.released(.left), x: 10, y: 20)
    }
}

// MARK: - Published skins

private func runSliderSkinPatternTests(_ t: TestRunner) {
    // VisBubble's settings window hands every press, drag and release to a Lua function with screen coordinates, and
    // moves itself while its background is dragged.
    t.suite("Plugin: Slider drives a Lua settings window that moves itself") {
        let script = """
        function Initialize()
            configX = tonumber(SKIN:GetVariable('CURRENTCONFIGX'))
            configY = tonumber(SKIN:GetVariable('CURRENTCONFIGY'))
        end

        function mouse_action(x, y, a)
            if a == 2 then
                configX = configX + x - lastX
                configY = configY + y - lastY
                SKIN:Bang('!Move', configX, configY)
            end
            lastX, lastY = x, y
            SKIN:Bang('!SetVariable', 'Log', SKIN:GetVariable('Log') .. x .. ',' .. y .. ',' .. a .. ';')
        end
        """
        let host = MovableHost()
        let skin = try sliderSkin(t, """
        [sUi]
        Measure=Script
        ScriptFile=Ui.lua

        [mRainUiMouseHandler]
        Measure=Plugin
        Plugin=Slider.dll
        ClickAction=[!CommandMeasure sUi "mouse_action($mouseX$, $mouseY$, 1)"]
        DragAction=[!CommandMeasure sUi "mouse_action($mouseX$, $mouseY$, 2)"]
        ReleaseAction=[!CommandMeasure sUi "mouse_action($mouseX$, $mouseY$, 3)"]
        RelativeToSkin=0
        """, files: ["Root/Sub/Ui.lua": script], host: host)
        t.equal(skin.issues, [])
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        // The pointer goes 20 right and 5 down on the screen: the window follows it to (120, 205).
        skin.pointerEvent(.dragged, x: 30, y: 15)
        t.check(host.origin.x == 120 && host.origin.y == 205, "moved to \(host.origin)")
        // 10 more to the right: in the moved window that is (20, 10); the window follows again, to (130, 205), and the
        // pointer is released where it is, (10, 10) in the window.
        skin.pointerEvent(.dragged, x: 20, y: 10)
        skin.pointerEvent(.released(.left), x: 10, y: 10)
        t.equal(log(skin), "110,210,1;130,215,2;140,215,2;140,215,3;", "screen coordinates of the moving window")
        t.check(host.origin.x == 130 && host.origin.y == 205, "moved to \(host.origin)")
    }

    // NXT-OS's scroll bars: the track's LeftMouseDownAction turns the Disabled=1 measure on, its ReleaseAction off.
    t.suite("Plugin: Slider turned on by the pressed meter drags until its ReleaseAction turns it off") {
        let skin = try sliderSkin(t, """
        [Scroll.Pos]
        Measure=Plugin
        Plugin=Slider.dll
        MouseButton=Left
        ClickAction=\(appending("click $mouseY$"))
        DragAction=\(appending("adjust $mouseY$"))
        ReleaseAction=[!SetVariable Log "[#Log]unlock;"][!SetOption Scroll.Pos Disabled 1][!Update]
        RelativeToSkin=1
        Disabled=1

        [Scroll.Bg]
        Meter=Image
        X=90
        W=10
        H=50
        SolidColor=180,180,180,255
        LeftMouseDownAction=[!SetOption Scroll.Pos Disabled 0][!Update]
        """)
        // The app reports a press to the measures first, then to the meters.
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 95, y: 10)
        skin.mouseEvent(.leftDown, x: 95, y: 10)
        t.equal(skin.measure(named: "Scroll.Pos")?.disabled, false, "the track turned it on")
        skin.pointerEvent(.dragged, x: 95, y: 30)
        skin.pointerEvent(.dragged, x: 95, y: 80)
        skin.pointerEvent(.released(.left), x: 95, y: 80)
        t.equal(log(skin), "adjust 30;adjust 80;unlock;",
                "no ClickAction for the press that turned it on; the drag goes on below the skin")
        t.equal(skin.measure(named: "Scroll.Pos")?.disabled, true, "its ReleaseAction turned it off")
        clearLog(skin)
        skin.pointerEvent(.pressed(.left, doubleClick: false), x: 10, y: 10)
        skin.mouseEvent(.leftDown, x: 10, y: 10)
        skin.pointerEvent(.dragged, x: 10, y: 20)
        skin.pointerEvent(.released(.left), x: 10, y: 20)
        t.equal(log(skin), "", "off: a press elsewhere on the skin runs nothing")
    }
}

// MARK: - Input elsewhere on the screen

private func runSliderOutsideTests(_ t: TestRunner) {
    t.suite("Plugin: Slider asks for the input outside the skin that its actions need") {
        let skin = try sliderSkin(t, """
        [Click]
        Measure=Plugin
        Plugin=Slider
        ClickAction=\(appending("click"))

        [Release]
        Measure=Plugin
        Plugin=Slider
        MouseButton=Right
        ReleaseAction=\(appending("release"))
        Disabled=1

        [Drag]
        Measure=Plugin
        Plugin=Slider
        MouseButton=Middle
        DragAction=\(appending("drag"))
        Disabled=1

        [Hold]
        Measure=Plugin
        Plugin=Slider
        MouseButton=Right
        HoldAction=\(appending("hold"))
        Disabled=1

        [Move]
        Measure=Plugin
        Plugin=Slider
        MoveAction=\(appending("move"))
        Disabled=1

        [Nothing]
        Measure=Plugin
        Plugin=Slider

        [Version3]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDownAction=\(appending("v3"))
        MouseMoveAction=\(appending("v3 move"))
        """)
        func needs() -> OutsidePointerNeeds { skin.outsidePointerNeeds }
        t.equal(needs(), OutsidePointerNeeds(buttons: [.left]),
                "ClickAction: presses and releases of the left button; no Mouse (version 3) measure, no empty Slider")
        func only(_ name: String) {
            let all = ["Click", "Release", "Drag", "Hold", "Move"]
            skin.execute(all.map { "[!\($0 == name ? "Enable" : "Disable")Measure \($0)]" }.joined(), from: nil)
        }
        only("Release")
        t.equal(needs(), OutsidePointerNeeds(buttons: [.right]), "a bang is enough, without an update")
        only("Drag")
        t.equal(needs(), OutsidePointerNeeds(buttons: [.middle], dragButtons: [.middle]))
        only("Hold")
        t.equal(needs(), OutsidePointerNeeds(buttons: [.right], dragButtons: [.right]),
                "a hold follows its press's drags: $MouseX$ is where the pointer is when the delay ends")
        only("Move")
        t.equal(needs(), OutsidePointerNeeds(moves: true), "every move only for a MoveAction")
        only("")
        t.check(needs().isEmpty, "disabled measures ask for nothing")
        skin.execute("[!EnableMeasure Click][!EnableMeasure Move][!PauseMeasure Click]", from: nil)
        t.equal(needs(), OutsidePointerNeeds(moves: true), "nor paused ones")
        skin.execute("[!UnpauseMeasure Click]", from: nil)
        t.equal(needs(), OutsidePointerNeeds(buttons: [.left], moves: true), "the needs of all measures together")
        skin.execute("[!SetOption Move MoveAction \"\"]", from: nil)
        t.equal(needs(), OutsidePointerNeeds(buttons: [.left]), "an option changed by a bang counts at once")
        skin.update()
        t.equal(needs(), OutsidePointerNeeds(buttons: [.left]))
        skin.close()
        t.check(needs().isEmpty, "a closed skin asks for nothing")
    }

    t.suite("Plugin: Slider runs its actions for input elsewhere on the screen") {
        let host = FakeHost()
        let skin = try sliderSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Slider
        ClickAction=\(appending("click $MouseX$,$MouseY$"))
        DragAction=\(appending("drag $MouseX$,$MouseY$"))
        ReleaseAction=\(appending("release $MouseX$,$MouseY$"))
        MoveAction=\(appending("move $MouseX$,$MouseY$"))

        [Version3]
        Measure=Plugin
        Plugin=Mouse
        LeftMouseDownAction=\(appending("v3"))
        MouseMoveAction=\(appending("v3 move"))
        UpdateRate=0
        """, host: host)
        t.equal(skin.outsidePointerNeeds, OutsidePointerNeeds(buttons: [.left], dragButtons: [.left], moves: true))
        skin.outsidePointerEvent(.moved, x: -300, y: 20)
        t.equal(log(skin), "move -300,20;", "a move elsewhere; the Mouse plugin (version 3) sees only its skin")
        clearLog(skin)
        skin.outsidePointerEvent(.pressed(.left, doubleClick: true), x: 400.6, y: -70.2)
        skin.outsidePointerEvent(.dragged, x: 410, y: -60)
        skin.outsidePointerEvent(.released(.left), x: 420, y: -50)
        t.equal(log(skin), "click 400,-71;move 410,-60;drag 410,-60;release 420,-50;",
                "a click far from the skin: whole points from the skin's corner, rounded down")
        clearLog(skin)
        skin.outsidePointerEvent(.released(.left), x: 1, y: 1)
        skin.outsidePointerEvent(.pressed(.right, doubleClick: false), x: 1, y: 1)
        skin.outsidePointerEvent(.released(.right), x: 1, y: 1)
        skin.outsidePointerEvent(.scrolled(.scrollUp), x: 1, y: 1)
        skin.outsidePointerEvent(.exited, x: 1, y: 1)
        t.equal(log(skin), "", "a release without its press, another button, the wheel: nothing")
        skin.outsidePointerEvent(.dragged, x: 2, y: 2)
        t.equal(log(skin), "move 2,2;", "a drag of a press not seen is a move")
        clearLog(skin)

        // A release that never arrived: the next move, or the next press of the button, reports it first.
        skin.outsidePointerEvent(.pressed(.left, doubleClick: false), x: 5, y: 5)
        skin.outsidePointerEvent(.moved, x: 6, y: 6)
        skin.outsidePointerEvent(.pressed(.left, doubleClick: false), x: 7, y: 7)
        skin.outsidePointerEvent(.pressed(.left, doubleClick: false), x: 8, y: 8)
        t.equal(log(skin), "click 5,5;release 6,6;move 6,6;click 7,7;release 8,8;click 8,8;")
        skin.outsidePointerEvent(.released(.left), x: 8, y: 8)
        clearLog(skin)

        // While the skin window reports the pointer over itself, a move from elsewhere is the same move.
        skin.pointerEvent(.moved, x: 50, y: 25)
        skin.outsidePointerEvent(.moved, x: 50, y: 25)
        t.equal(log(skin), "move 50,25;v3 move;", "reported once, by the skin window")
        skin.outsidePointerEvent(.pressed(.left, doubleClick: false), x: 51, y: 25)
        skin.outsidePointerEvent(.dragged, x: 52, y: 25)
        skin.outsidePointerEvent(.released(.left), x: 52, y: 25)
        t.equal(log(skin), "move 50,25;v3 move;click 51,25;move 52,25;drag 52,25;release 52,25;",
                "presses, drags and releases elsewhere still count (a press on a transparent pixel, another app's drag)")
        clearLog(skin)
        skin.outsidePointerEvent(.moved, x: 150, y: 25)
        t.equal(log(skin), "move 150,25;", "away from the skin, even if its window never said the pointer left (hidden)")
        clearLog(skin)
        // Hidden (!Hide) or made click-through during a press while the pointer was over it: its window says nothing
        // more, and a move over its area is input from elsewhere, though the window never said the pointer left.
        host.windowTakesPointer = false
        skin.outsidePointerEvent(.moved, x: 55, y: 25)
        t.equal(log(skin), "move 55,25;", "over a skin whose window no longer gets the mouse")
        host.windowTakesPointer = true
        skin.outsidePointerEvent(.moved, x: 56, y: 25)
        t.equal(log(skin), "move 55,25;", "shown again with the pointer over it: its window reports the move")
        clearLog(skin)
        skin.pointerEvent(.exited, x: -1, y: -1)
        skin.outsidePointerEvent(.moved, x: 60, y: 25)
        t.equal(log(skin), "move 60,25;", "over the skin once its window no longer reports the pointer (ClickThrough)")
        clearLog(skin)

        // Disabled: nothing is asked for and nothing runs; a press held meanwhile is forgotten.
        skin.outsidePointerEvent(.pressed(.left, doubleClick: false), x: 1, y: 1)
        skin.execute("[!DisableMeasure M]", from: nil)
        skin.outsidePointerEvent(.released(.left), x: 1, y: 1)
        skin.execute("[!EnableMeasure M]", from: nil)
        skin.outsidePointerEvent(.moved, x: 3, y: 3)
        t.equal(log(skin), "click 1,1;move 3,3;", "no late ReleaseAction for a press whose release nobody watched")
    }

    t.suite("Plugin: Slider holds a press made elsewhere, in file order with other Slider measures") {
        let skin = try sliderSkin(t, """
        [First]
        Measure=Plugin
        Plugin=Slider
        ClickAction=\(appending("first click"))
        HoldAction=\(appending("first hold $MouseX$,$MouseY$"))
        HoldDelay=0

        [Second]
        Measure=Plugin
        Plugin=Slider
        ClickAction=\(appending("second click"))
        ReleaseAction=\(appending("second release"))
        """)
        skin.outsidePointerEvent(.pressed(.left, doubleClick: false), x: -10, y: -10)
        skin.outsidePointerEvent(.dragged, x: -20, y: -30)
        t.equal(log(skin), "first click;second click;")
        t.check(spin(until: { log(skin).contains("hold") }), "held")
        t.equal(log(skin), "first click;second click;first hold -20,-30;", "where the pointer is then")
        skin.outsidePointerEvent(.released(.left), x: -20, y: -30)
        t.equal(log(skin), "first click;second click;first hold -20,-30;second release;")
    }

    t.suite("Plugin: Slider RelativeToSkin=0 gives screen coordinates for input elsewhere") {
        let skin = try sliderSkin(t, """
        [M]
        Measure=Plugin
        Plugin=Slider
        ClickAction=[!SetVariable P "$MouseX$ $MouseY$"]
        RelativeToSkin=0
        """, host: MovableHost())
        skin.outsidePointerEvent(.pressed(.left, doubleClick: false), x: -150, y: 900)
        t.equal(skin.variable("P"), "-50 1100", "the skin at (100, 200): a point left of the primary screen")
        skin.outsidePointerEvent(.released(.left), x: -150, y: 900)
    }
}
