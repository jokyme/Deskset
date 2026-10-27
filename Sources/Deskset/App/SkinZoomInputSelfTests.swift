import AppKit
import DesksetCore

enum SkinZoomInputSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: skin zoom input: actions, hover, tooltips and external pointer coordinates") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("ZoomInput")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try fixture.write(to: folder.appendingPathComponent("Input.ini"), atomically: true, encoding: .utf8)
            app.rescanLibrary()
            guard let c = app.activate(config: "ZoomInput", file: "Input.ini") else { return t.check(false, "loads") }
            for percent in [10, 100, 150, 500] {
                c.requestZoom(percent: percent)
                let zoom = Double(percent) / 100
                t.check(AppSelfTest.spin { c.runtime.snapshot.zoomFactor == zoom && c.window.frame.width == 100 * zoom })
                c.runtime.send(.exited)
                c.skin.setVariable("Clicked", "0")
                c.skin.setVariable("Hovered", "0")
                guard let down = AppSelfTest.mouseEvent(.leftMouseDown, c, x: 20 * zoom, y: 20 * zoom),
                      let up = AppSelfTest.mouseEvent(.leftMouseUp, c, x: 20 * zoom, y: 20 * zoom),
                      let hover = AppSelfTest.mouseEvent(.mouseMoved, c, x: 20 * zoom, y: 20 * zoom) else {
                    return t.check(false, "mouse events")
                }
                c.view.mouseDown(with: down)
                c.view.mouseUp(with: up)
                t.equal(c.skin.variable("Clicked"), "1", "the scaled rectangle gets its click at \(percent)%")
                c.view.mouseMoved(with: hover)
                t.equal(c.skin.variable("Hovered"), "1", "scaled hover reaches the same meter")
                t.equal(c.view.cursorName, "HAND")
                c.view.updateToolTips()
                t.check(c.view.toolTipRects.contains(CGRect(x: 10 * zoom, y: 10 * zoom,
                                                           width: 20 * zoom, height: 20 * zoom)))
                let target = c.view.logicalPoint(NSPoint(x: 20 * zoom, y: 20 * zoom))
                t.equal(c.view.toolTipText(x: target.0, y: target.1), "Scaled target")
                let screenPoint = c.window.convertPoint(toScreen: c.view.convert(NSPoint(x: 20 * zoom, y: 20 * zoom),
                                                                                to: nil))
                let logical = c.skinPoint(fromScreen: screenPoint)
                t.close(logical.x, 20)
                t.close(logical.y, 20)
                c.skin.setVariable("Clicked", "0")
                if let down = AppSelfTest.mouseEvent(.leftMouseDown, c, x: 40 * zoom, y: 20 * zoom),
                   let up = AppSelfTest.mouseEvent(.leftMouseUp, c, x: 40 * zoom, y: 20 * zoom) {
                    c.view.mouseDown(with: down)
                    c.view.mouseUp(with: up)
                }
                t.equal(c.skin.variable("Clicked"), "0", "the unoccupied area does not activate the meter")
            }
        }

        t.suite("App: skin zoom input: Ctrl Option selection suppresses skin actions and tooltips") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("ZoomInput")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try fixture.write(to: folder.appendingPathComponent("Input.ini"), atomically: true, encoding: .utf8)
            app.rescanLibrary()
            guard let c = app.activate(config: "ZoomInput", file: "Input.ini"),
                  let down = AppSelfTest.mouseEvent(.leftMouseDown, c, x: 20, y: 20, flags: [.control, .option]),
                  let up = AppSelfTest.mouseEvent(.leftMouseUp, c, x: 20, y: 20, flags: [.control, .option]) else { return }
            c.view.mouseDown(with: down)
            t.check(!c.isSelected, "selection toggles on release")
            c.view.mouseUp(with: up)
            t.check(c.isSelected)
            t.equal(c.skin.variable("Clicked"), "0")
            t.check(c.view.acceptsFirstResponder && c.view.needsPanelToBecomeKey)
            c.view.updateToolTips()
            t.equal(c.view.toolTipRects, [])
            t.equal(c.view.toolTipText(x: 20, y: 20), nil)
            if let moved = AppSelfTest.mouseEvent(.mouseMoved, c, x: 20, y: 20) { c.view.mouseMoved(with: moved) }
            t.equal(c.skin.variable("Hovered"), "0")
            c.view.mouseDown(with: down)
            c.view.mouseUp(with: up)
            t.check(!c.isSelected)
            t.equal(c.view.toolTipRects, [CGRect(x: 10, y: 10, width: 20, height: 20)])
            t.equal(c.skin.variable("Clicked"), "0")
        }

        t.suite("App: skin zoom input: selecting during an ordinary press releases input on both executors") {
            for threading in [SkinThreading.main, .engine] {
                guard let app = try AppSelfTest.makeApp(t, threading: threading) else { return }
                let folder = app.skinsDirectory.appendingPathComponent("ZoomInput")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try fixture.write(to: folder.appendingPathComponent("Input.ini"), atomically: true, encoding: .utf8)
                app.rescanLibrary()
                guard let c = app.activate(config: "ZoomInput", file: "Input.ini") else { return }
                t.check(AppSelfTest.spin { c.isStarted })
                guard let down = AppSelfTest.mouseEvent(.leftMouseDown, c, x: 40, y: 40),
                      let up = AppSelfTest.mouseEvent(.leftMouseUp, c, x: 40, y: 40, flags: [.control, .option]) else { return }
                c.view.mouseDown(with: down)
                t.check(c.isDragPressActive)
                t.equal(c.view.pointerPresses, [.left])
                c.view.mouseUp(with: up)
                t.check(c.isSelected)
                t.check(!c.isDragPressActive)
                t.check(c.view.pointerPresses.isEmpty)
                t.equal(c.view.heldButtons, 0)
                app.skinSelection.clear()
                t.check(!c.isSelected)
                t.check(c.runtime.exclusive(timeout: 5) { $0.variable("Clicked") == "0" } ?? false)
            }
        }

        t.suite("App: skin zoom input: Studio inherits desktop zoom without enlarging its logical canvas") {
            guard let app = try AppSelfTest.makeApp(t),
                  let c = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
            let host = StudioHost()
            host.desktop = c
            let preview = Skin(config: c.config, fileURL: c.fileURL, skinsDirectory: app.skinsDirectory,
                               system: SystemMonitor.shared, host: host)
            try preview.load()
            defer { preview.close() }
            c.requestZoom(percent: 150)
            var environment = host.environment(for: preview)
            t.close(environment.zoomFactor, 1.5)
            t.close(environment.defaultZoomFactor, 1)
            t.check(!environment.forceDefaultZoom)
            t.close(environment.windowFrame.width, preview.width)
            t.close(environment.windowFrame.height, preview.height)
            preview.invalidateEnvironment()
            t.equal(preview.variable("CURRENTCONFIGZOOM"), "150")
            app.setDefaultZoom(percent: 125, force: true)
            environment = host.environment(for: preview)
            t.close(environment.zoomFactor, 1.25)
            t.close(environment.defaultZoomFactor, 1.25)
            t.check(environment.forceDefaultZoom)
            preview.invalidateEnvironment()
            t.equal(preview.variable("CURRENTCONFIGZOOM"), "125")
            app.setDefaultZoom(percent: nil, force: false)
            preview.invalidateEnvironment()
            t.equal(preview.variable("CURRENTCONFIGZOOM"), "150")
        }
    }

    private static let fixture = """
    [Rainmeter]
    Update=-1
    SkinWidth=100
    SkinHeight=80
    [Variables]
    Clicked=0
    Hovered=0
    [Target]
    Meter=Image
    X=10
    Y=10
    W=20
    H=20
    SolidColor=220,60,30,255
    LeftMouseDownAction=[!SetVariable Clicked 1]
    MouseOverAction=[!SetVariable Hovered 1]
    MouseLeaveAction=[!SetVariable Hovered 0]
    MouseActionCursor=1
    MouseActionCursorName=HAND
    ToolTipText=Scaled target
    """
}
