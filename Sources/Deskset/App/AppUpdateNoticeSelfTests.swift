import AppKit

enum AppUpdateNoticeSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Updates: notice buttons describe the available actions") {
            let state = AppState(fileURL: t.temporaryDirectory("update-notice").appendingPathComponent("state.json"))
            let app = AppController(state: state, presentsWindows: false)
            let release = AppRelease(version: ReleaseVersion("0.3.0")!,
                                     url: URL(string: "https://github.com/jokyme/Deskset/releases/tag/v0.3.0")!)
            let offer = app.updateNoticePresentation(.available(release))
            t.equal(offer.title, "Deskset 0.3.0 is available")
            t.equal(offer.buttons, ["Update", "Skip This Version", "Close"])
            t.check(offer.text.contains("0.3.0"))
            t.check(offer.text.contains("asks before it restarts"), "downloading does not quit the app without confirmation")
            t.equal(state.updates.skippedVersion, nil, "constructing a notice changes no preference")
            for notice: AppUpdateController.Notice in [.upToDate, .noRelease, .failed("Offline")] {
                let result = app.updateNoticePresentation(notice)
                t.equal(result.buttons, ["Close"])
            }
        }
    }
}
