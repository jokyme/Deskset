import AppKit
import DesksetCore

enum AboutSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: About: version information and independent window") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let about = app.showAbout()
            defer { about.close(); DebugWindowController.window(for: app)?.close() }
            t.equal(about.selectedTab, .version)
            let details = about.currentVersionDetails()
            t.check(details.headline.hasPrefix("Deskset \(AppVersion.current)"))
            t.check(details.headline.contains(AboutWindowController.buildArchitecture))
            t.equal(details.iniFile, app.state.fileURL.path)
            t.equal(details.skinPath, app.skinsDirectory.path + "/")
            t.equal(details.settingsPath, app.settingsDirectory.path + "/")
            t.equal(details.logFile, Log.fileURL.path)
            about.copyVersionDetailsToClipboard()
            t.equal(NSPasteboard.general.string(forType: .string), about.versionReportText())
            app.openLogAction()
            t.equal(DebugWindowController.window(for: app)?.selectedTab, .log)
            t.equal(about.selectedTab, .version, "opening diagnostics keeps About on version information")
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                about.window?.appearance = NSAppearance(named: appearance)
                about.window?.setContentSize(NSSize(width: 680, height: 398))
                let bitmap = about.snapshot()
                let scale = about.window?.backingScaleFactor ?? 1
                t.equal(bitmap?.pixelsWide, Int(680 * scale))
                t.equal(bitmap?.pixelsHigh, Int(398 * scale))
            }
        }
    }
}
