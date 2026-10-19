import AppKit
import DesksetCore

enum DebugEntryLifecycleSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Debug entry lifecycle: restore a selected skin and reject stale window work") {
            let root = t.temporaryDirectory("debug-entry-lifecycle")
            let nativeWindows = NSApp.activationPolicy() != .prohibited
            let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                    skinsDirectory: root.appendingPathComponent("Skins"),
                                    layoutsDirectory: root.appendingPathComponent("Layouts"),
                                    backupsDirectory: root.appendingPathComponent("Backups"),
                                    settingsDirectory: root.appendingPathComponent("Settings"),
                                    presentsWindows: nativeWindows, threading: .engine,
                                    layoutWallpaper: MemoryLayoutWallpaper())
            defer {
                DebugWindowController.window(for: app)?.close()
                app.stopAllForTermination()
                app.endEngineThread()
            }
            try SkinLifecycleSelfTests.write(app, [
                "Alpha": SkinLifecycleSelfTests.plainSkin,
                "Beta": SkinLifecycleSelfTests.plainSkin,
            ])
            // Native-window runs may show the Debug dialog, but never place temporary widgets on the desktop.
            for config in ["Life\\Alpha", "Life\\Beta"] {
                app.state.update(config) { $0.startHidden = true }
            }
            guard let alpha = app.activate(config: "Life\\Alpha", file: nil),
                  let beta = app.activate(config: "Life\\Beta", file: nil) else {
                return t.check(false, "both lifecycle fixtures load")
            }
            t.check(AppSelfTest.spin { alpha.isStarted && beta.isStarted })
            let debug = app.showDebug(tab: .skins, config: alpha.config)
            guard let window = debug.window else { return t.check(false, "Debug owns a window") }
            t.check(AppSelfTest.spin { debug.skinInspector.currentSkinState?.config == alpha.config })

            let blocked = SkinLifecycleSelfTests.Gate()
            blocked.hold(alpha.runtime.executor)
            defer { blocked.open() }
            debug.selectTab(.skins, config: alpha.config)

            var miniaturizedNatively = false
            if nativeWindows {
                window.miniaturize(nil)
                miniaturizedNatively = AppSelfTest.spin(timeout: 2) { window.isMiniaturized }
            }
            if !miniaturizedNatively {
                // The self-test process normally prohibits visible windows and Dock integration. Exercise the same
                // delegate stop/restart callbacks there; a regular application run also covers real miniaturization.
                print("    (headless: exercising Debug minimize/restore delegate callbacks)")
                debug.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification, object: window))
            }

            let restored = app.showDebug(tab: .skins, config: beta.config)
            t.check(restored === debug, "restoring reuses the existing Debug controller")
            if miniaturizedNatively {
                t.check(AppSelfTest.spin(timeout: 2) { !window.isMiniaturized }, "show restores the native window")
            } else {
                debug.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification, object: window))
            }
            t.equal(debug.selectedTab, .skins)
            t.equal(debug.skinInspector.selectedSkinConfig, beta.config,
                    "the requested config survives restoring the window")
            blocked.open()
            t.check(AppSelfTest.spin {
                debug.skinInspector.currentSkinState?.config == beta.config && SkinDebugProbe.activeSlotCount == 0
            }, "the old Alpha request cannot replace Beta after restore")

            debug.selectTab(.plugins)
            debug.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification, object: window))
            t.equal(debug.selectedTab, .plugins, "a late restore callback preserves the current tab")

            let closing = SkinLifecycleSelfTests.Gate()
            closing.hold(alpha.runtime.executor)
            defer { closing.open() }
            debug.selectTab(.skins, config: alpha.config)
            debug.close()
            t.check(DebugWindowController.window(for: app) == nil)
            let reopened = app.showDebug(tab: .skins, config: beta.config)
            t.check(reopened !== debug, "closing releases the old shared controller")
            debug.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
            debug.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification, object: window))
            t.check(DebugWindowController.window(for: app) === reopened,
                    "late notifications from the closed window cannot release the new window")
            closing.open()
            t.check(AppSelfTest.spin {
                reopened.skinInspector.currentSkinState?.config == beta.config && SkinDebugProbe.activeSlotCount == 0
            }, "queued work from the old window cannot restore its skin into the reopened window")
            t.equal(reopened.selectedTab, .skins)
            t.equal(reopened.skinInspector.selectedSkinConfig, beta.config)
        }
    }
}
