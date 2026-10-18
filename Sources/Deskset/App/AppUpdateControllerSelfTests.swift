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
        t.suite("App: Updates: closing an offer allows a later daily reminder") {
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
            t.equal(notices.count, 2, "Close dismisses this check; the next daily check can remind again")
            now.addTimeInterval(AppUpdateController.checkInterval)
            controller.checkAutomaticallyIfDue()
            fetcher.completions[2](.success(release("0.4.0")))
            t.equal(notices.count, 3, "a newer version is announced")
            state.saveNow()
            let reopened = AppState(fileURL: state.fileURL)
            let next = AppUpdateController(state: reopened, service: fetcher, currentVersion: "0.2.0", now: { now })
            next.checkAutomaticallyIfDue()
            t.equal(fetcher.completions.count, 3, "relaunch preserves the check interval")
            t.equal(next.availableRelease?.version, ReleaseVersion("0.4.0"), "relaunch preserves the update hint")
        }

        t.suite("App: Updates: skip survives relaunch and manual Close does not reset it") {
            let state = state(t), fetcher = Fetcher(), update = release("0.3.0")
            var now = Date(timeIntervalSince1970: 1_000_000)
            let controller = AppUpdateController(state: state, service: fetcher, currentVersion: "0.2.0", now: { now })
            var notices = 0
            controller.onNotice = { [weak controller] notice, automatic in
                t.equal(notice, .available(update))
                t.check(automatic)
                notices += 1
                controller?.skipUpdate(update)
                return true
            }
            controller.checkAutomaticallyIfDue()
            fetcher.completions[0](.success(update))
            t.equal(notices, 1)
            t.equal(state.updates.skippedVersion, "0.3.0")
            t.equal(state.updates.lastNotifiedVersion, nil, "returning from a skipped alert must not restore its hint")
            t.equal(controller.availableRelease, nil)
            t.equal(controller.status, .idle)
            state.saveNow()

            let reopened = AppState(fileURL: state.fileURL)
            let next = AppUpdateController(state: reopened, service: fetcher, currentVersion: "0.2.0", now: { now })
            t.equal(next.availableRelease, nil, "no skipped badge is restored on launch")
            next.onNotice = { _, _ in notices += 1; return true }
            now.addTimeInterval(AppUpdateController.checkInterval)
            next.checkAutomaticallyIfDue()
            fetcher.completions[1](.success(update))
            t.equal(notices, 1, "automatic checks still run without prompting about a skipped version")
            t.equal(next.availableRelease, nil)

            next.onNotice = { notice, automatic in
                t.equal(notice, .available(update))
                t.check(!automatic)
                notices += 1
                return true // Close, without changing the skip choice.
            }
            next.checkManually()
            fetcher.completions[2](.success(update))
            t.equal(notices, 2, "manual checks offer skipped releases")
            t.equal(reopened.updates.skippedVersion, "0.3.0")
            t.equal(reopened.updates.lastNotifiedVersion, nil)
            t.equal(next.availableRelease, nil, "a manual Close does not reactivate the badge")
            next.showAvailableUpdate()
            t.equal(notices, 2)
            now.addTimeInterval(AppUpdateController.checkInterval)
            next.checkAutomaticallyIfDue()
            fetcher.completions[3](.success(update))
            t.equal(notices, 2, "the next automatic check still respects Skip")

            let newer = release("0.4.0")
            next.onNotice = { notice, automatic in
                t.equal(notice, .available(newer))
                t.check(automatic)
                notices += 1
                return true
            }
            now.addTimeInterval(AppUpdateController.checkInterval)
            next.checkAutomaticallyIfDue()
            fetcher.completions[4](.success(newer))
            t.equal(notices, 3, "skipping one version does not suppress a newer version")
            t.equal(next.availableRelease, newer)
            t.equal(reopened.updates.lastNotifiedVersion, "0.4.0")
            next.skipUpdate(update)
            t.equal(next.availableRelease, newer, "an old alert's Skip cannot hide a newer offer")
            t.equal(next.status, .available(newer))
            t.equal(reopened.updates.lastNotifiedVersion, "0.4.0")
        }

        t.suite("App: Updates: skipped hints and skipping an existing menu offer") {
            let state = state(t), fetcher = Fetcher(), update = release("0.3.0")
            state.updateUpdates {
                $0.lastNotifiedVersion = "0.3.0"
                $0.skippedVersion = "v0.3.0+build.1"
            }
            let skipped = AppUpdateController(state: state, service: fetcher, currentVersion: "0.2.0")
            t.equal(skipped.availableRelease, nil, "a skipped version suppresses stale cached hints too")
            t.equal(skipped.status, .idle)
            state.updateUpdates { $0.skippedVersion = nil }
            let controller = AppUpdateController(state: state, service: fetcher, currentVersion: "0.2.0")
            t.equal(controller.availableRelease?.version, update.version, "older preference files retain their update hint")
            controller.onNotice = { [weak controller] notice, automatic in
                t.check(!automatic)
                if case .available(let offered) = notice {
                    t.equal(offered.version, update.version)
                } else {
                    t.check(false, "the cached release is offered")
                }
                controller?.skipUpdate(update)
                return true
            }
            controller.showAvailableUpdate()
            t.equal(controller.availableRelease, nil)
            t.equal(state.updates.lastNotifiedVersion, nil)
            t.equal(state.updates.skippedVersion, "0.3.0")
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
