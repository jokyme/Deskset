import AppKit
import DesksetCore

/// Original zoom fixtures exercise stored settings, layout interchange and the asynchronous window boundary.
enum SkinZoomSelfTests {
    static func run(_ t: AppTestRunner) {
        stateTests(t)
        modelTests(t)
        runtimeTests(t)
        selectionFlagTests(t)
        coreBangAnchorTests(t)
    }

    private static func stateTests(_ t: AppTestRunner) {
        t.suite("App: skin zoom: Default and explicit 100 survive JSON and layout round trips") {
            let decoder = JSONDecoder(), encoder = JSONEncoder()
            let inherited = try decoder.decode(SkinState.self, from: Data(#"{"file":"Main.ini"}"#.utf8))
            let explicit = try decoder.decode(SkinState.self, from: Data(#"{"file":"Main.ini","zoomFactor":1}"#.utf8))
            let rounded = try decoder.decode(SkinState.self, from: Data(#"{"file":"Main.ini","zoomFactor":1.237}"#.utf8))
            t.equal(inherited.zoomOverridePercent, nil)
            t.equal(explicit.zoomOverridePercent, 100)
            t.equal(rounded.zoomOverridePercent, 124)
            t.equal(try decoder.decode(SkinState.self, from: encoder.encode(explicit)).zoomOverridePercent, 100)
            t.equal(try decoder.decode(SkinState.self, from: encoder.encode(inherited)).zoomOverridePercent, nil)
            let document = IniDocument.parse("""
            [Rainmeter]
            DefaultZoom=150
            ForceDefaultZoom=0
            [Default]
            Active=0
            [Explicit]
            Active=0
            Zoom=100
            [Zero]
            Active=0
            Zoom=0
            [Prefix]
            Active=0
            Zoom=125tail
            """)
            let layout = LayoutStateCodec.decode(document, library: [])
            t.equal(layout.skins["Default"]?.zoomOverridePercent, nil)
            t.equal(layout.skins["Explicit"]?.zoomOverridePercent, 100)
            t.equal(layout.skins["Zero"]?.zoomOverridePercent, 10)
            t.equal(layout.skins["Prefix"]?.zoomOverridePercent, 125)
            let state = AppState(fileURL: t.temporaryDirectory("zoom-state").appendingPathComponent("state.json"))
            state.replaceLayout(layout)
            t.equal(state.defaultZoomPercent, 150)
            state.update("Explicit") { $0.zoomOverridePercent = nil }
            let captured = LayoutStateCodec.capture(state.data, library: [], options: LayoutSaveOptions())
            t.equal(captured.section(named: "Explicit")?["Zoom"], nil, "Default removes retained imported Zoom")
            state.update("Default") { $0.zoomOverridePercent = 100 }
            let explicitCapture = LayoutStateCodec.capture(state.data, library: [], options: LayoutSaveOptions())
            t.equal(explicitCapture.section(named: "Default")?["Zoom"], "100")
            state.saveNow()
            let reopened = AppState(fileURL: state.fileURL)
            t.equal(reopened.defaultZoomPercent, 150)
            t.equal(reopened.skin("Default")?.zoomOverridePercent, 100)
            t.equal(reopened.skin("Explicit")?.zoomOverridePercent, nil)
        }

        t.suite("App: skin zoom: global keys preserve case and ordinary layouts retain zoom preferences") {
            let state = AppState(fileURL: t.temporaryDirectory("zoom-global").appendingPathComponent("state.json"))
            state.replaceLayout(LayoutState(skins: [:], order: [], rainmeterOptions: [
                "defaultzoom": "150", "FORCEDEFAULTZOOM": "0", "SelectedColor": "1,2,3", "Other": "kept"
            ]))
            state.setDefaultZoom(percent: 700, force: true)
            t.equal(state.defaultZoomPercent, 500)
            t.check(state.forceDefaultZoom)
            t.equal(state.data.rainmeterOptions["defaultzoom"], "500")
            t.equal(state.data.rainmeterOptions["FORCEDEFAULTZOOM"], "1")
            t.equal(state.data.rainmeterOptions["Other"], "kept")
            let previous = LayoutState(skins: [:], order: [], rainmeterOptions: state.data.rainmeterOptions)
            let target = LayoutState(skins: [:], order: [], rainmeterOptions: ["DefaultZoom": "90", "ForceDefaultZoom": "0"])
            let merged = target.preservingSettings(from: previous)
            t.equal(merged.rainmeterOptions["DefaultZoom"], "500")
            t.equal(merged.rainmeterOptions["ForceDefaultZoom"], "1")
            state.replaceLayout(target)
            t.equal(state.defaultZoomPercent, 90, "direct backup replacement restores its own global settings")
            t.check(!state.forceDefaultZoom)
            state.setDefaultZoom(percent: 0, force: nil)
            t.equal(state.defaultZoomPercent, 10, "zero is clamped, not a Default sentinel")
        }

        t.suite("App: skin zoom: selection defers disk writes without hiding live settings") {
            let state = AppState(fileURL: t.temporaryDirectory("zoom-selection").appendingPathComponent("state.json"))
            state.update("Card") { $0.file = "Main.ini"; $0.zoomOverridePercent = 125; $0.x = 20 }
            state.saveNow()
            state.beginSkinSelection("card")
            state.update("Card") { $0.zoomOverridePercent = 175; $0.x = 40 }
            state.saveNow()
            t.equal(state.skin("Card")?.zoomOverridePercent, 175)
            let during = AppState(fileURL: state.fileURL)
            t.equal(during.skin("Card")?.zoomOverridePercent, 125)
            t.equal(during.skin("Card")?.x, 20)
            state.endSkinSelection("CARD")
            state.saveNow()
            let after = AppState(fileURL: state.fileURL)
            t.equal(after.skin("Card")?.zoomOverridePercent, 175)
            t.equal(after.skin("Card")?.x, 40)
        }
    }

    private static func modelTests(_ t: AppTestRunner) {
        t.suite("App: skin zoom: forced defaults, selection flags and scaled absolute anchors") {
            var state = SkinState(file: "Main.ini")
            state.zoomOverridePercent = 200
            state.anchorX = "20"
            state.anchorY = "10"
            state.draggable = false
            state.clickThrough = true
            var model = SkinWindowModel()
            model.take(SkinWindowFacts(frame: CGRect(x: 100, y: 200, width: 100, height: 50), isVisible: true,
                                       scale: 1, takesPointer: true,
                                       settings: SkinWindowSettings(state, hidden: false, fadedAlpha: nil,
                                                                    defaultZoomPercent: 150, forceDefaultZoom: true,
                                                                    isSelected: true), sequence: 1))
            t.equal(model.settings.zoomFactor, 1.5)
            t.check(model.settings.effectiveDraggable && !model.settings.effectiveClickThrough
                    && !model.settings.effectiveKeepOnScreen)
            t.equal(model.apply(Bang(name: "setzoomfactor", args: ["3"]), screens: [])?.operation, nil)
            t.equal(model.settings.zoomOverridePercent, 200)
            _ = model.apply(Bang(name: "setzoomfactor", args: ["Default"]), screens: [])
            t.equal(model.settings.zoomOverridePercent, nil)
            t.equal(model.settings.zoomFactor, 1.5)
            model.resize(to: CGSize(width: 150, height: 75), zoomFactor: 1.5, screens: [])
            t.equal(model.frame, CGRect(x: 90, y: 180, width: 150, height: 75), "the scaled absolute anchor stays fixed")
            let screens = [WindowGeometry.Screen(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                                  visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))]
            let point = WindowPosition.resolve(x: "200", y: "100", anchorX: "20", anchorY: "10",
                                               skinSize: CGSize(width: 150, height: 75), screens: screens, zoomFactor: 1.5)
            t.equal(point?.x, 170)
            t.equal(point?.y, 85)
            let saved = WindowPosition.moved(x: 170, y: 85, windowX: "200", windowY: "100", anchorX: "20", anchorY: "10",
                                             skinSize: CGSize(width: 150, height: 75), screens: screens,
                                             autoSelectScreen: false, zoomFactor: 1.5)
            t.equal(saved.x, "200")
            t.equal(saved.y, "100")
        }
    }

    private static func selectionFlagTests(_ t: AppTestRunner) {
        for mode: SkinThreading in [.main, .engine] {
            t.suite("App: skin zoom: \(mode.rawValue) selected flag bangs stay temporary and menus update saved values") {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return }
                try SkinWindowModelSelfTests.write(app, ["SelectedFlags": """
                [Rainmeter]
                Update=-1
                [Extent]
                Meter=Image
                W=100
                H=60
                """])
                var tracked: [() -> Skin?] = []
                autoreleasepool {
                    guard let c = app.activate(config: "Model\\SelectedFlags", file: nil) else {
                        return t.check(false, "selected flag fixture loads")
                    }
                    tracked.append(EngineThreadSelfTests.track(c))
                    t.check(SkinWindowModelSelfTests.settled(c))
                    app.changeSettings(of: c) { $0.draggable = true; $0.clickThrough = false; $0.keepOnScreen = false }
                    app.skinSelection.toggle(c)
                    t.check(c.facts.settings.effectiveDraggable)
                    t.check(!c.facts.settings.effectiveClickThrough && !c.facts.settings.effectiveKeepOnScreen)
                    c.runtime.send(.execute("[!Draggable -1][!ClickThrough -1][!KeepOnScreen -1]", section: nil))
                    t.check(AppSelfTest.spin(timeout: 30) {
                        let settings = c.facts.settings
                        return !settings.effectiveDraggable && settings.effectiveClickThrough && settings.effectiveKeepOnScreen
                    }, "toggle bangs use the temporary effective values")
                    t.check(c.window.ignoresMouseEvents, "a selected ClickThrough bang takes effect")
                    t.check(c.state.draggable && !c.state.clickThrough && !c.state.keepOnScreen,
                            "bangs do not overwrite the saved settings")
                    app.changeSettings(of: c) { $0.draggable = false; $0.keepOnScreen = true }
                    t.check(!c.facts.settings.effectiveDraggable && c.facts.settings.effectiveClickThrough,
                            "menu edits retain the temporary values until deselection")
                    app.skinSelection.clear()
                    t.check(AppSelfTest.spin(timeout: 30) {
                        c.runtime.exclusive { _ in c.runtime.model.settings.isSelected == false } == true
                    })
                    let restored = c.facts.settings
                    t.check(!restored.effectiveDraggable && !restored.effectiveClickThrough && restored.effectiveKeepOnScreen)
                    t.check(restored.selectedFlagOverrides.isEmpty)
                    t.check(!c.window.ignoresMouseEvents)
                    t.check(!c.state.draggable && !c.state.clickThrough && c.state.keepOnScreen,
                            "deselection restores the values most recently saved by the menus")
                    app.deactivate(config: c.config)
                }
                EngineThreadSelfTests.finish(t, app, tracked)
            }
        }
    }

    private static func coreBangAnchorTests(_ t: AppTestRunner) {
        for mode: SkinThreading in [.main, .engine] {
            t.suite("App: skin zoom: \(mode.rawValue) core and group bangs keep absolute and percentage anchors") {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return }
                EnvironmentStore.shared.publish()
                let fixture = """
                [Rainmeter]
                Update=-1
                Group=AnchoredZoom
                [Extent]
                Meter=Image
                W=100
                H=60
                """
                try SkinWindowModelSelfTests.write(app, ["AbsoluteZoom": fixture, "PercentZoom": fixture])
                app.state.setDefaultZoom(percent: 150, force: false)
                for name in ["AbsoluteZoom", "PercentZoom"] {
                    app.state.update("Model\\" + name) {
                        $0.file = name + ".ini"
                        $0.zoomOverridePercent = 100
                        $0.windowX = "400"
                        $0.windowY = "300"
                        $0.anchorX = name == "AbsoluteZoom" ? "20" : "50%"
                        $0.anchorY = name == "AbsoluteZoom" ? "10" : "50%"
                        $0.keepOnScreen = false
                    }
                }
                var tracked: [() -> Skin?] = []
                autoreleasepool {
                    guard let absolute = app.activate(config: "Model\\AbsoluteZoom", file: nil),
                          let percentage = app.activate(config: "Model\\PercentZoom", file: nil) else {
                        return t.check(false, "anchored zoom fixtures load")
                    }
                    tracked = [absolute, percentage].map(EngineThreadSelfTests.track)
                    t.check(SkinWindowModelSelfTests.settled(absolute))
                    t.check(SkinWindowModelSelfTests.settled(percentage))
                    let starts = [absolute.window.frame, percentage.window.frame]
                    let initialFacts = absolute.publishedFacts
                    func verify(_ controller: SkinWindowController, index: Int, zoom: Double) {
                        let start = starts[index]
                        let anchorX = index == 0 ? 20.0 : 50.0
                        let anchorY = index == 0 ? 10.0 : 30.0
                        let expected = CGRect(x: start.minX + anchorX * (1 - zoom),
                                              y: start.maxY + anchorY * (zoom - 1) - 60 * zoom,
                                              width: 100 * zoom, height: 60 * zoom)
                        t.check(AppSelfTest.spin(timeout: 30) {
                            controller.window.frame == expected && controller.runtime.snapshot.zoomFactor == zoom
                        }, "core requests reach the anchored window at \(zoom)")
                        let model = controller.runtime.exclusive { _ in controller.runtime.model }
                        t.equal(model?.frame, expected, "the acknowledged model matches the actual window")
                        t.equal(model?.frameZoomFactor, zoom, "the model records the zoom of its existing frame")
                        t.equal(controller.state.windowX, "400", "zoom does not rewrite the saved X expression")
                        t.equal(controller.state.windowY, "300", "zoom does not rewrite the saved Y expression")
                    }
                    // Call the engine entry point directly; this exercises its early display request before the host bang.
                    let seen = absolute.runtime.exclusive { skin -> String? in
                        skin.execute("[!SetZoomFactor 1.5][!SetVariable ZoomRead #CURRENTCONFIGZOOM#]", from: nil)
                        return skin.variable("ZoomRead")
                    }
                    t.equal(seen, "150")
                    verify(absolute, index: 0, zoom: 1.5)
                    t.equal(percentage.zoomOverridePercent, 100, "an own bang does not affect its group peer")
                    _ = absolute.runtime.exclusive { skin in
                        skin.execute("[!SetZoomFactorGroup 2 AnchoredZoom]", from: nil)
                    }
                    verify(absolute, index: 0, zoom: 2)
                    verify(percentage, index: 1, zoom: 2)
                    t.equal(absolute.zoomOverridePercent, 200)
                    t.equal(percentage.zoomOverridePercent, 200)
                    _ = percentage.runtime.exclusive { skin in
                        skin.execute("[!SetZoomFactorGroup Default AnchoredZoom]", from: nil)
                    }
                    verify(absolute, index: 0, zoom: 1.5)
                    verify(percentage, index: 1, zoom: 1.5)
                    t.equal(absolute.zoomOverridePercent, nil)
                    t.equal(percentage.zoomOverridePercent, nil)
                    if let initialFacts { absolute.runtime.send(.windowFacts(initialFacts)) }
                    absolute.runtime.send(.redraw)
                    verify(absolute, index: 0, zoom: 1.5)
                    t.equal(absolute.runtime.exclusive { $0.variable("CURRENTCONFIGZOOM") }, "150",
                            "an older facts message cannot restore the previous zoom")
                    app.deactivate(config: absolute.config)
                    app.deactivate(config: percentage.config)
                }
                EngineThreadSelfTests.finish(t, app, tracked)
            }
        }
    }

    private static func runtimeTests(_ t: AppTestRunner) {
        for mode: SkinThreading in [.main, .engine] {
            t.suite("App: skin zoom: \(mode.rawValue) Default, force, latest facts and resize completion") {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return }
                EnvironmentStore.shared.publish()
                try SkinWindowModelSelfTests.write(app, ["Zoom": """
                [Rainmeter]
                Update=-1
                DefaultZoomFactor=3
                Group=ZoomGroup
                [Extent]
                Meter=Image
                W=100
                H=60
                """])
                app.state.setDefaultZoom(percent: 150, force: false)
                var tracked: [() -> Skin?] = []
                autoreleasepool {
                    guard let controller = app.activate(config: "Model\\Zoom", file: nil) else {
                        return t.check(false, "zoom fixture loads")
                    }
                    tracked.append(EngineThreadSelfTests.track(controller))
                    t.check(SkinWindowModelSelfTests.settled(controller))
                    t.equal(controller.window.frame.size, CGSize(width: 150, height: 90))
                    t.equal(controller.zoomOverridePercent, nil)
                    t.equal(controller.runtime.exclusive { $0.variable("CURRENTCONFIGZOOM") }, "150")
                    var completed = false
                    controller.requestZoom(percent: 100) {
                        t.equal(controller.window.frame.size, CGSize(width: 100, height: 60), "resize precedes acknowledgement")
                        completed = true
                    }
                    t.check(AppSelfTest.spin(timeout: 30) { completed })
                    t.equal(controller.zoomOverridePercent, 100)
                    app.state.setDefaultZoom(percent: 180, force: false)
                    controller.refreshZoomSettings()
                    t.check(SkinWindowModelSelfTests.settled(controller))
                    t.equal(controller.window.frame.size, CGSize(width: 100, height: 60), "explicit 100 ignores default changes")
                    app.state.setDefaultZoom(percent: nil, force: true)
                    controller.refreshZoomSettings()
                    t.check(AppSelfTest.spin(timeout: 30) { controller.window.frame.size == CGSize(width: 180, height: 108) })
                    completed = false
                    controller.requestZoom(percent: 250) { completed = true }
                    t.check(AppSelfTest.spin(timeout: 30) { completed })
                    t.equal(controller.zoomOverridePercent, 100, "force retains the pre-existing custom value")
                    completed = false
                    controller.requestZoom(percent: nil) { completed = true }
                    t.check(AppSelfTest.spin(timeout: 30) { completed })
                    t.equal(controller.zoomOverridePercent, nil, "Default can clear a forced override")
                    app.state.setDefaultZoom(percent: 125, force: false)
                    controller.refreshZoomSettings()
                    t.check(AppSelfTest.spin(timeout: 30) { controller.window.frame.size == CGSize(width: 125, height: 75) })
                    t.equal(controller.runtime.exclusive { $0.variable("CURRENTCONFIGZOOM") }, "125")
                    t.equal(controller.runtime.exclusive { $0.effectiveZoomFactor }, 1.25)
                    controller.runtime.send(.execute("[!SetZoomFactor 1.237][!SetVariable SeenZoom #CURRENTCONFIGZOOM#]", section: nil))
                    t.equal(controller.runtime.exclusive { $0.variable("SeenZoom") }, "124", "bang factors round to percentages")
                    t.check(AppSelfTest.spin(timeout: 30) { controller.zoomOverridePercent == 124 })
                    controller.runtime.send(.execute("[!SetZoomFactorGroup Default ZoomGroup]", section: nil))
                    t.check(AppSelfTest.spin(timeout: 30) {
                        controller.zoomOverridePercent == nil && controller.window.frame.size == CGSize(width: 125, height: 75)
                    })
                    let logical = controller.skinPoint(fromScreen: NSPoint(x: controller.window.frame.minX + 25,
                                                                            y: controller.window.frame.maxY - 12.5))
                    t.close(logical.x, 20)
                    t.close(logical.y, 10)
                    completed = false
                    controller.requestZoom(percent: 500) { completed = true }
                    t.check(AppSelfTest.spin(timeout: 30) { completed })
                    let beforeShift = controller.window.frame
                    let desiredTop = NSPoint(x: beforeShift.minX + 20, y: beforeShift.maxY - 10)
                    controller.zoomPositionOverride = desiredTop
                    completed = false
                    controller.requestZoom(percent: 500) {
                        t.equal(controller.window.frame.minX, desiredTop.x, "a peer at the zoom limit still moves")
                        t.equal(controller.window.frame.maxY, desiredTop.y)
                        t.equal(controller.window.frame.size, beforeShift.size)
                        completed = true
                    }
                    t.check(AppSelfTest.spin(timeout: 30) { completed })
                    controller.zoomPositionOverride = nil
                    app.deactivate(config: controller.config)
                }
                EngineThreadSelfTests.finish(t, app, tracked)
            }
        }
    }
}
