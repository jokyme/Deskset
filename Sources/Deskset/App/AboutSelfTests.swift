import AppKit
import DesksetCore

enum AboutSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: About: version information in Settings window") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            CodeEditorRoutingSelfTests.withFakes(.init(), .init()) {
                let settings = app.showAbout()
                defer {
                    settings.close()
                    DebugWindowController.window(for: app)?.close()
                }
                t.equal(settings.pane, .about)
                t.equal(settings.settingsModel.pane, .about)
                t.equal(settings.window?.title, L("About Deskset"))
                let details = AboutWindowController.versionDetails(for: app)
                t.check(details.headline.hasPrefix("Deskset \(AppVersion.current)"))
                t.check(details.headline.contains(AboutWindowController.buildArchitecture))
                t.equal(details.iniFile, app.state.fileURL.path)
                t.equal(details.skinPath, app.skinsDirectory.path + "/")
                t.equal(details.settingsPath, app.settingsDirectory.path + "/")
                t.equal(details.logFile, Log.fileURL.path)
                settings.copyVersionDetailsToClipboard()
                t.equal(NSPasteboard.general.string(forType: .string), settings.versionReportText())
                app.openLogAction()
                t.equal(DebugWindowController.window(for: app)?.selectedTab, .log)
                t.equal(settings.pane, .about, "opening diagnostics keeps Settings on About Deskset")
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    settings.window?.appearance = NSAppearance(named: appearance)
                    let bitmap = settings.snapshot()
                    t.equal(bitmap?.pixelsWide, Int(SettingsWindowController.defaultSize.width * 2))
                    t.equal(bitmap?.pixelsHigh, Int(SettingsWindowController.defaultSize.height * 2))
                }
                settings.window?.appearance = nil
            }
        }
    }
}
