import AppKit

enum AppUpdateControllerSelfTests {
    private final class Fetcher: AppUpdateFetching {
        var completions: [(Result<AppRelease?, Error>) -> Void] = []
        var cancellations = 0
        func fetch(completion: @escaping (Result<AppRelease?, Error>) -> Void) -> () -> Void {
            completions.append(completion)
            return { [weak self] in self?.cancellations += 1 }
        }
    }

    private static func release(_ version: String) -> AppRelease {
        AppRelease(version: ReleaseVersion(version)!, url: URL(string: "https://github.com/jokyme/Deskset/releases/tag/v\(version)")!)
    }

    private static func state(_ t: AppTestRunner) -> AppState {
        AppState(fileURL: t.temporaryDirectory("updates").appendingPathComponent("state.json"))
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Updates: daily checks and notification deduplication") {
            let state = state(t), fetcher = Fetcher()
            var now = Date(timeIntervalSince1970: 1_000_000)
            let controller = AppUpdateController(state: state, service: fetcher, currentVersion: "0.2.0", now: { now })
            var notices: [AppUpdateController.Notice] = []
            controller.onNotice = { notice, automatic in
                t.check(automatic)
                notices.append(notice)
                return true
            }
            controller.checkAutomaticallyIfDue()
            t.equal(fetcher.completions.count, 1)
            t.check(controller.isChecking)
            let update = release("0.3.0")
            fetcher.completions[0](.success(update))
            t.equal(controller.status, .available(update))
            t.equal(notices, [.available(update)])
            t.equal(state.updates.lastNotifiedVersion, "0.3.0")
            controller.checkAutomaticallyIfDue()
            t.equal(fetcher.completions.count, 1, "throttled within a day")
            now.addTimeInterval(AppUpdateController.checkInterval)
            controller.checkAutomaticallyIfDue()
            fetcher.completions[1](.success(update))
            t.equal(notices.count, 1, "same version stays in the menu without another automatic alert")
            now.addTimeInterval(AppUpdateController.checkInterval)
            controller.checkAutomaticallyIfDue()
            fetcher.completions[2](.success(release("0.4.0")))
            t.equal(notices.count, 2, "a newer version is announced")
            state.saveNow()
            let reopened = AppState(fileURL: state.fileURL)
            let next = AppUpdateController(state: reopened, service: fetcher, currentVersion: "0.2.0", now: { now })
            next.checkAutomaticallyIfDue()
            t.equal(fetcher.completions.count, 3, "relaunch preserves the check interval")
            t.equal(next.availableRelease?.version, ReleaseVersion("0.4.0"), "relaunch preserves the update hint")
        }

        t.suite("App: Updates: manual feedback and joining an in-flight check") {
            let state = state(t), fetcher = Fetcher()
            let controller = AppUpdateController(state: state, service: fetcher, currentVersion: "0.2.0")
            var notices: [AppUpdateController.Notice] = []
            controller.onNotice = { notice, automatic in
                t.check(!automatic)
                notices.append(notice)
                return true
            }
            controller.checkAutomaticallyIfDue()
            controller.checkManually()
            controller.checkManually()
            t.equal(fetcher.completions.count, 1, "manual clicks reuse the automatic request")
            fetcher.completions[0](.success(release("0.2.0")))
            t.equal(controller.status, .upToDate)
            t.equal(notices, [.upToDate])
            controller.checkManually()
            fetcher.completions[1](.success(nil))
            t.equal(controller.status, .noRelease)
            t.equal(notices.last, .noRelease)
            controller.checkManually()
            fetcher.completions[2](.failure(URLError(.notConnectedToInternet)))
            if case .failed = notices.last { t.check(true) } else { t.check(false, "manual network failure is shown") }
            controller.checkManually()
            fetcher.completions[3](.success(release("0.1.0")))
            t.equal(controller.status, .upToDate, "never offers a downgrade")
        }

        t.suite("App: Updates: automatic failures are quiet and manual retry is immediate") {
            let state = state(t), fetcher = Fetcher()
            let controller = AppUpdateController(state: state, service: fetcher, currentVersion: "0.2.0")
            var notices = 0
            controller.onNotice = { _, _ in notices += 1; return true }
            controller.checkAutomaticallyIfDue()
            fetcher.completions[0](.failure(URLError(.timedOut)))
            t.equal(notices, 0)
            t.check(controller.statusText.contains("Couldn’t check"))
            controller.checkAutomaticallyIfDue()
            t.equal(fetcher.completions.count, 1, "a failed check is throttled too")
            controller.checkManually()
            t.equal(fetcher.completions.count, 2)
            fetcher.completions[1](.success(release("0.3.0")))
            t.equal(notices, 1)
        }

        t.suite("App: Updates: disabling and termination ignore late completions") {
            let state = state(t), fetcher = Fetcher()
            let controller = AppUpdateController(state: state, service: fetcher, currentVersion: "0.2.0")
            var notices = 0
            controller.onNotice = { _, _ in notices += 1; return true }
            controller.checkAutomaticallyIfDue()
            controller.setAutomaticallyChecks(false)
            t.equal(fetcher.cancellations, 1)
            fetcher.completions[0](.success(release("0.3.0")))
            t.equal(controller.status, .idle)
            t.equal(notices, 0)
            controller.checkAutomaticallyIfDue()
            t.equal(fetcher.completions.count, 1)
            controller.checkManually()
            controller.setAutomaticallyChecks(false)
            t.check(controller.isChecking, "turning off automatic checks does not cancel a manual check")
            fetcher.completions[1](.success(release("0.3.0")))
            t.equal(notices, 1)
            controller.checkManually()
            controller.stop()
            fetcher.completions[2](.success(release("0.4.0")))
            t.equal(controller.availableRelease, release("0.3.0"))
            t.equal(notices, 1)
        }

        t.suite("App: Updates: deferred notices, clock correction and invalid installed version") {
            let state = state(t), fetcher = Fetcher()
            var now = Date(timeIntervalSince1970: 1_000_000)
            state.updateUpdates { $0.lastCheckAttempt = now.addingTimeInterval(100) }
            let controller = AppUpdateController(state: state, service: fetcher, currentVersion: "0.2.0", now: { now })
            controller.onNotice = { _, _ in false }
            controller.checkAutomaticallyIfDue()
            t.equal(fetcher.completions.count, 1, "a future timestamp cannot suppress checks forever")
            fetcher.completions[0](.success(release("0.3.0")))
            t.equal(state.updates.lastNotifiedVersion, nil, "a busy UI has not delivered the notice")
            now.addTimeInterval(AppUpdateController.checkInterval)
            var notices = 0
            controller.onNotice = { _, _ in notices += 1; return true }
            controller.checkAutomaticallyIfDue()
            fetcher.completions[1](.success(release("0.3.0")))
            t.equal(notices, 1)
            controller.showAvailableUpdate()
            t.equal(notices, 2, "the release remains reachable after dismissing the alert")
            let bad = AppUpdateController(state: state, service: fetcher, currentVersion: "broken")
            bad.checkManually()
            t.equal(fetcher.completions.count, 2)
            t.check(bad.statusText.contains("installed version"))
        }

        t.suite("App: Updates: menus, settings and headless notices") {
          CodeEditorRoutingSelfTests.withFakes(.init(), .init()) {
            let state = state(t)
            let app = AppController(state: state, presentsWindows: false)
            let fetcher = Fetcher()
            app.updates = AppUpdateController(state: state, service: fetcher, currentVersion: "0.2.0")
            let main = MainMenu.make(app: app)
            let menu = NSMenu()
            app.buildMainMenu(menu)
            for items in [main.items.first?.submenu?.items ?? [], menu.items] {
                t.check(items.contains { $0.title == "Check for Updates…" && $0.action == #selector(AppController.checkForUpdatesAction) })
            }
            let settings = SettingsWindowController(app: app)
            settings.select(.general)
            t.equal(settings.automaticUpdatesBox.state, .on)
            t.equal(settings.checkUpdatesButton.action, #selector(AppController.checkForUpdatesAction))
            t.check(settings.updateStatusLabel.stringValue.contains("0.2.0"))
            t.check(settings.viewUpdateButton.isHidden)
            app.updates.setAutomaticallyChecks(false)
            t.equal(settings.automaticUpdatesBox.state, .off)
            t.check(settings.snapshot() != nil)
            let initialHeight = settings.window?.frame.height ?? 0
            app.updates.checkManually()
            t.check(!settings.checkUpdatesButton.isEnabled)
            fetcher.completions[0](.success(release("0.3.0")))
            t.check(settings.checkUpdatesButton.isEnabled)
            t.check(!settings.viewUpdateButton.isHidden)
            t.check(settings.updateStatusLabel.stringValue.contains("0.3.0"))
            app.buildMainMenu(menu)
            t.check(menu.items.contains { $0.title == "Update to Deskset 0.3.0…" })
            app.updates.checkManually()
            fetcher.completions[1](.failure(AppUpdateError.invalidResponse))
            t.check((settings.window?.frame.height ?? 0) > initialHeight, "multiline errors grow the General pane")
            if let view = settings.window?.contentView {
                t.check(view.bounds.height >= ceil(view.fittingSize.height), "status text is not clipped")
            }
            t.check(app.showUpdateNotice(.available(release("0.3.0")), automatic: false))
            t.check(app.lastAlert?.text.contains("0.3.0") == true)
            t.check(app.showUpdateNotice(.failed("Offline"), automatic: false))
            t.check(app.lastAlert?.text.contains("Offline") == true)
            settings.close()
          }
        }
    }
}
