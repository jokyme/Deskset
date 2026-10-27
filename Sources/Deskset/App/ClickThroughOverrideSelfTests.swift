import AppKit
import DesksetCore

/// ClickThrough's Ctrl override on the Mac: ⌘ or Control held over a click-through skin (`ClickThroughOverride`).
enum ClickThroughOverrideSelfTests {
    final class FakeState: ClickThroughOverride.State {
        var modifierFlags: NSEvent.ModifierFlags = []
        var pressedMouseButtons = 0
        var pointerLocation = NSPoint(x: -10_000, y: -10_000)
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: ClickThrough: ⌘ or Control over the skin lets the mouse reach it") {
            guard let (app, a, b) = try fixture(t) else { return }
            let fake = FakeState()
            app.clickThroughOverride.state = fake
            defer { app.clickThroughOverride.state = ClickThroughOverride.SystemState() }
            app.changeSettings(of: a) { $0.clickThrough = true }
            app.changeSettings(of: b) { $0.clickThrough = true }
            t.check(a.window.ignoresMouseEvents && b.window.ignoresMouseEvents, "click-through skins ignore the mouse")
            t.check(a.passesMouseThrough)

            app.clickThroughOverride.tick()
            t.check(a.window.ignoresMouseEvents, "no key held")
            fake.modifierFlags = [.command]
            app.clickThroughOverride.tick()
            t.check(a.window.ignoresMouseEvents, "⌘ held with the pointer elsewhere")

            fake.pointerLocation = NSPoint(x: a.window.frame.midX, y: a.window.frame.midY)
            app.clickThroughOverride.tick()
            t.check(!a.window.ignoresMouseEvents && a.clickThroughOverridden, "⌘ over the skin")
            t.check(!a.passesMouseThrough)
            t.check(b.window.ignoresMouseEvents, "only the skin under the pointer")
            a.visibilityForTesting = false
            app.clickThroughOverride.tick()
            t.check(a.window.ignoresMouseEvents, "a skin that is not on screen is left alone")
            a.visibilityForTesting = true
            app.clickThroughOverride.tick()
            t.check(a.state.clickThrough, "the saved setting is unchanged")

            fake.pressedMouseButtons = 1
            fake.modifierFlags = []
            app.clickThroughOverride.tick()
            t.check(!a.window.ignoresMouseEvents, "a press under way keeps it after the key is released")
            fake.pointerLocation = NSPoint(x: -10_000, y: -10_000)
            app.clickThroughOverride.tick()
            t.check(!a.window.ignoresMouseEvents, "even when the drag leaves the window")
            fake.pressedMouseButtons = 0
            app.clickThroughOverride.tick()
            t.check(a.window.ignoresMouseEvents && !a.clickThroughOverridden, "the mouse passes through again")

            fake.modifierFlags = [.control, .option]
            fake.pointerLocation = NSPoint(x: b.window.frame.midX, y: b.window.frame.midY)
            app.clickThroughOverride.tick()
            t.check(!b.window.ignoresMouseEvents, "Control (and Control-Option for selecting) works too")
            fake.modifierFlags = [.option]
            app.clickThroughOverride.tick()
            t.check(b.window.ignoresMouseEvents, "Option alone does not")

            fake.modifierFlags = [.command]
            fake.pressedMouseButtons = 1
            app.clickThroughOverride.tick()
            t.check(b.window.ignoresMouseEvents, "a press that started elsewhere starts no override")
            fake.pressedMouseButtons = 0

            app.clickThroughOverride.tick()
            t.check(!b.window.ignoresMouseEvents)
            app.changeSettings(of: b) { $0.clickThrough = false }
            t.check(!b.clickThroughOverridden, "turning click-through off ends the override")
            app.changeSettings(of: a) { $0.clickThrough = false }
            app.clickThroughOverride.tick()
            t.check(!app.clickThroughOverride.isWatching, "nothing to watch without click-through skins")
        }
    }

    private static func fixture(_ t: AppTestRunner) throws -> (AppController, SkinWindowController, SkinWindowController)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        var skins: [SkinWindowController] = []
        for name in ["A", "B"] {
            let config = "ClickThroughOverride\\" + name
            let folder = SkinLibrary.directory(for: config, root: app.skinsDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
            [Rainmeter]
            Update=-1
            [Face]
            Meter=Image
            W=120
            H=80
            SolidColor=40,90,150,255
            """.write(to: folder.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
            app.state.update(config) {
                $0.file = "Skin.ini"
                $0.x = name == "A" ? 200 : 400
                $0.y = 200
                $0.keepOnScreen = false
                $0.snapEdges = false
            }
            guard let skin = app.activate(config: config, file: "Skin.ini") else {
                t.check(false, "click-through fixture loads")
                return nil
            }
            t.check(AppSelfTest.spin { skin.isStarted })
            skin.pauseUpdates()
            skin.visibilityForTesting = true
            skins.append(skin)
        }
        t.atSuiteEnd { app.stopAllForTermination() }
        return (app, skins[0], skins[1])
    }
}
