import AppKit
import DesksetCore

/// Layout coordinates are exercised with original INI fixtures and deterministic virtual monitor geometry.
enum LayoutPositionSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Layouts coordinates: new skin defaults retain their coordinate syntax") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("LayoutDefaults")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
            [Rainmeter]
            Update=-1
            DefaultWindowX=(100 / 2)%
            DefaultWindowY=50%
            DefaultAnchorX=50%
            DefaultAnchorY=50%
            [Card]
            Meter=Image
            W=100
            H=100
            SolidColor=40,70,90,255
            """.write(to: folder.appendingPathComponent("Card.ini"), atomically: true, encoding: .utf8)
            app.rescanLibrary()
            guard let c = app.activate(config: "LayoutDefaults", file: nil) else { return t.check(false, "skin loaded") }
            t.check(AppSelfTest.spin { c.isStarted })
            try app.saveLayout(named: "Default position", options: LayoutSaveOptions())
            let section = try app.layoutStore.read(named: "Default position").ini.section(named: "LayoutDefaults")
            t.equal(section?["WindowX"], "(100 / 2)%")
            t.equal(section?["WindowY"], "50%")
            t.equal(section?["AnchorX"], "50%")
            t.equal(section?["AnchorY"], "50%")
            let expected = WindowPosition.resolve(x: "50%", y: "50%", anchorX: "50%", anchorY: "50%",
                skinSize: c.window.frame.size, screens: EnvironmentStore.shared.currentScreens)
            t.close(c.topLeftPosition.x, expected?.x ?? -1)
            t.close(c.topLeftPosition.y, expected?.y ?? -1)
        }

        t.suite("App: Layouts coordinates: monitor inheritance and moved relative positions") {
            let screens = [AppSelfTest.screen, AppSelfTest.screen2]
            let size = CGSize(width: 200, height: 100)
            let yMonitor = WindowPosition.resolve(x: "10", y: "20@2", anchorX: "0", anchorY: "0",
                                                 skinSize: size, screens: screens)
            t.close(yMonitor?.x ?? -1, 1450, "a monitor suffix on Y also applies to X")
            t.close(yMonitor?.y ?? -1, 20)
            let moved = WindowPosition.moved(x: 2500, y: 500, windowX: "(100 / 2)%R", windowY: "50%B@2",
                anchorX: "50%", anchorY: "0B", skinSize: size, screens: screens, autoSelectScreen: false)
            t.check(moved.x.hasSuffix("%R") && moved.y.hasSuffix("%B@2"), "moving retains relative syntax")
            let restored = WindowPosition.resolve(x: moved.x, y: moved.y, anchorX: "50%", anchorY: "0B",
                                                  skinSize: size, screens: screens)
            t.close(restored?.x ?? -1, 2500)
            t.close(restored?.y ?? -1, 500)
            let auto = WindowPosition.moved(x: 1800, y: 200, windowX: nil, windowY: nil,
                anchorX: nil, anchorY: nil, skinSize: size, screens: screens, autoSelectScreen: true)
            t.equal(auto.x, "360@2")
            t.equal(auto.y, "200@2")
            let virtual = WindowPosition.moved(x: 1500, y: 200, windowX: "50%@0", windowY: "50%",
                anchorX: "50%", anchorY: "50%", skinSize: size, screens: screens, autoSelectScreen: false)
            let roundTrip = WindowPosition.resolve(x: virtual.x, y: virtual.y, anchorX: "50%", anchorY: "50%",
                                                  skinSize: size, screens: screens)
            t.close(roundTrip?.x ?? -1, 1500)
            t.close(roundTrip?.y ?? -1, 200)
        }

        t.suite("App: Layouts coordinates: percentage anchors, resize, drag and SavePosition") {
            for savePosition in [true, false] {
                guard let app = try AppSelfTest.makeApp(t) else { continue }
                let directory = app.skinsDirectory.appendingPathComponent("LayoutPosition")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try """
                [Rainmeter]
                Update=-1
                DynamicWindowSize=1
                [Card]
                Meter=Image
                W=200
                H=100
                SolidColor=40,70,90,255
                """.write(to: directory.appendingPathComponent("Card.ini"), atomically: true, encoding: .utf8)
                app.rescanLibrary()
                let ini = IniDocument.parse("""
                [LayoutPosition]
                Active=1
                WindowX=50%
                WindowY=50%
                AnchorX=50%
                AnchorY=50%
                SavePosition=\(savePosition ? 1 : 0)
                KeepOnScreen=0
                """)
                try app.layoutStore.save(LayoutDocument(ini: ini), named: "Centered")
                var loaded = false
                app.loadLayout(named: "Centered") { loaded = $0 }
                t.check(AppSelfTest.spin { loaded })
                guard let c = app.controller(for: "LayoutPosition") else { return t.check(false, "skin loaded") }
                let expected = WindowPosition.resolve(x: "50%", y: "50%", anchorX: "50%", anchorY: "50%",
                    skinSize: c.window.frame.size, screens: EnvironmentStore.shared.currentScreens)
                t.close(c.topLeftPosition.x, expected?.x ?? -1)
                t.close(c.topLeftPosition.y, expected?.y ?? -1)
                c.moveTo(x: 300, y: 250)
                c.runtime.send(.execute("[!SetOption Card W 400][!UpdateMeter Card][!Redraw]", section: nil))
                t.check(AppSelfTest.spin { c.window.frame.width == 400 })
                t.close(c.topLeftPosition.x, 200, "resizing preserves the moved center even when SavePosition=0")
                t.close(c.topLeftPosition.y, 250)
                try app.saveLayout(named: "Moved", options: LayoutSaveOptions())
                let saved = try app.layoutStore.read(named: "Moved").ini.section(named: "LayoutPosition")
                t.equal(saved?["AnchorX"], "50%")
                if savePosition {
                    let point = WindowPosition.resolve(x: saved?["WindowX"] ?? "", y: saved?["WindowY"] ?? "",
                        anchorX: "50%", anchorY: "50%", skinSize: c.window.frame.size, screens: EnvironmentStore.shared.currentScreens)
                    t.close(point?.x ?? -1, 200)
                    t.close(point?.y ?? -1, 250)
                    // Reload the same size from the file so a saved percentage also survives a new window.
                    let file = directory.appendingPathComponent("Card.ini")
                    let source = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "W=200", with: "W=400")
                    try source.write(to: file, atomically: true, encoding: .utf8)
                    loaded = false
                    app.loadLayout(named: "Moved") { loaded = $0 }
                    t.check(AppSelfTest.spin { loaded })
                    t.close(app.controller(for: "LayoutPosition")?.topLeftPosition.x ?? -1, 200)
                    t.close(app.controller(for: "LayoutPosition")?.topLeftPosition.y ?? -1, 250)
                } else {
                    t.equal(saved?["WindowX"], "50%", "a temporary drag must not replace the saved position")
                    t.equal(saved?["WindowY"], "50%")
                    c.placeWindow()
                    t.close(c.topLeftPosition.x, 200, "session placement follows the resized window")
                    t.close(c.topLeftPosition.y, 250)
                }
                if let current = app.controller(for: "LayoutPosition") {
                    current.beginDragPress()
                    current.runtime.send(.execute("[!SetWindowPosition 40% 30% 10 20][!Move 200 200]", section: nil))
                    current.endDragPress(moved: false)
                    t.equal(app.state.skin("LayoutPosition")?.anchorX, "10", "a held Move keeps a preceding anchor change")
                    t.equal(app.state.skin("LayoutPosition")?.anchorY, "20")
                    if savePosition {
                        t.check(app.state.skin("LayoutPosition")?.windowX?.hasSuffix("%") == true)
                    }
                }
            }
        }

        t.suite("App: Layouts coordinates: display disconnect and reconnect preserve saved and session positions") {
            defer {
                WindowGeometry.screensOverrideForTesting = nil
                EnvironmentStore.shared.publishScreens()
            }
            let dual = [AppSelfTest.screen, AppSelfTest.screen2]
            let single = [AppSelfTest.screen]
            let widerScreen2 = WindowGeometry.Screen(frame: CGRect(x: 1440, y: -540, width: 2560, height: 1440),
                                                     visibleFrame: CGRect(x: 1440, y: -540, width: 2560, height: 1440))
            func setScreens(_ list: [WindowGeometry.Screen], on app: AppController? = nil) {
                WindowGeometry.screensOverrideForTesting = list
                if let app { app.screensChanged() } else { EnvironmentStore.shared.publishScreens() }
            }

            for savePosition in [true, false] {
                setScreens(dual)
                guard let app = try AppSelfTest.makeApp(t) else { continue }
                let directory = app.skinsDirectory.appendingPathComponent("MonitorReturn")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try """
                [Rainmeter]
                Update=-1
                DynamicWindowSize=1
                [Card]
                Meter=Image
                W=200
                H=100
                SolidColor=40,70,90,255
                """.write(to: directory.appendingPathComponent("Card.ini"), atomically: true, encoding: .utf8)
                app.rescanLibrary()
                let ini = IniDocument.parse("""
                [MonitorReturn]
                Active=1
                WindowX=200@2
                WindowY=100@2
                SavePosition=\(savePosition ? 1 : 0)
                KeepOnScreen=1
                """)
                try app.layoutStore.save(LayoutDocument(ini: ini), named: "Dual")
                var loaded = false
                app.loadLayout(named: "Dual") { loaded = $0 }
                t.check(AppSelfTest.spin { loaded })
                guard let c = app.controller(for: "MonitorReturn") else { return t.check(false, "skin loaded") }
                t.close(c.topLeftPosition.x, 1640, "placed on @2 initially (SavePosition=\(savePosition))")
                t.close(c.topLeftPosition.y, 100)

                // DynamicWindowSize resize without a drag must not fabricate a session move.
                c.runtime.send(.execute("[!SetOption Card W 240][!UpdateMeter Card][!Redraw]", section: nil))
                t.check(AppSelfTest.spin { c.window.frame.width == 240 })
                t.check(app.sessionPositions[c.config.lowercased()] == nil)

                // Disconnect @2 -> falls back to @1 without rewriting saved @2 coordinates.
                setScreens(single, on: app)
                t.close(c.topLeftPosition.x, 200, "falls back to primary monitor while @2 is disconnected")
                t.close(c.topLeftPosition.y, 100)
                t.equal(c.state.windowX, "200@2")
                t.equal(c.state.windowY, "100@2")

                // Reconnect @2 -> returns to @2 even when SavePosition=0.
                setScreens(dual, on: app)
                t.close(c.topLeftPosition.x, 1640, "returns to @2 on reconnect (SavePosition=\(savePosition))")
                t.close(c.topLeftPosition.y, 100)
            }

            // Moving while SavePosition=1, then turning SavePosition off, keeps relative @2 resolution across changes.
            setScreens(dual)
            if let app = try AppSelfTest.makeApp(t) {
                let directory = app.skinsDirectory.appendingPathComponent("LockedRelative")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try """
                [Rainmeter]
                Update=-1
                [Card]
                Meter=Image
                W=200
                H=100
                SolidColor=40,70,90,255
                """.write(to: directory.appendingPathComponent("Card.ini"), atomically: true, encoding: .utf8)
                app.rescanLibrary()
                let ini = IniDocument.parse("""
                [LockedRelative]
                Active=1
                WindowX=50%
                WindowY=100
                AnchorX=50%
                AnchorY=0
                SavePosition=1
                KeepOnScreen=1
                """)
                try app.layoutStore.save(LayoutDocument(ini: ini), named: "Rel")
                var loaded = false
                app.loadLayout(named: "Rel") { loaded = $0 }
                t.check(AppSelfTest.spin { loaded })
                if let c = app.controller(for: "LockedRelative") {
                    c.moveTo(x: 620, y: 120)
                    app.changeSettings(of: c) { $0.savePosition = false }
                    t.check(app.sessionPositions[c.config.lowercased()] == nil,
                            "disabling SavePosition clears any prior saved move")
                    let item = app.displayMonitorMenu(for: c).items.first { $0.title.hasPrefix("@2:") }
                    t.check(item != nil)
                    if let item, let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) }
                    t.check(app.sessionPositions[c.config.lowercased()] == nil,
                            "selecting @2 without an unsaved drag keeps expression resolution active")
                    let expectedDual = WindowPosition.resolve(x: c.state.windowX ?? "0", y: c.state.windowY ?? "0",
                        anchorX: "50%", anchorY: "0", skinSize: c.window.frame.size, screens: dual)
                    t.close(c.topLeftPosition.x, expectedDual?.x ?? -1)
                    setScreens(single, on: app)
                    let expectedSingle = WindowPosition.resolve(x: c.state.windowX ?? "0", y: c.state.windowY ?? "0",
                        anchorX: "50%", anchorY: "0", skinSize: c.window.frame.size, screens: single)
                    t.close(c.topLeftPosition.x, expectedSingle?.x ?? -1)
                    setScreens([AppSelfTest.screen, widerScreen2], on: app)
                    let expectedWider = WindowPosition.resolve(x: c.state.windowX ?? "0", y: c.state.windowY ?? "0",
                        anchorX: "50%", anchorY: "0", skinSize: c.window.frame.size,
                        screens: [AppSelfTest.screen, widerScreen2])
                    t.close(c.topLeftPosition.x, expectedWider?.x ?? -1,
                            "percentage on @2 adapts to a wider external monitor with SavePosition=0")

                    // A temporary session move onto @2 clamps onto @1 while unplugged and returns for the session.
                    c.moveTo(x: 1800, y: 220)
                    let savedX = c.state.windowX
                    setScreens(single, on: app)
                    t.close(c.topLeftPosition.x, 1240, "clamped onto @1 while @2 is unplugged")
                    t.equal(c.state.windowX, savedX, "display clamping never commits an unsaved drag")
                    setScreens(dual, on: app)
                    t.close(c.topLeftPosition.x, 1800, "temporary session move returns to @2 when reconnected")
                    t.close(c.topLeftPosition.y, 220)
                }
            }
        }
    }
}
