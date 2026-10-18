import AppKit

enum AppUpdateFlowSelfTests {
    private final class Fetcher: AppUpdateFetching {
        var callbacks: [(Result<AppRelease?, Error>) -> Void] = []
        var cancellations = 0
        func fetch(completion: @escaping (Result<AppRelease?, Error>) -> Void) -> () -> Void {
            callbacks.append(completion)
            return { self.cancellations += 1 }
        }
    }

    private final class Downloader: AppUpdateDownloading {
        var callbacks: [(Result<AppPreparedUpdate, Error>) -> Void] = []
        var progress: [(Double?) -> Void] = []
        var cancellations = 0
        func download(_ release: AppRelease, progress: @escaping (Double?) -> Void,
                      completion: @escaping (Result<AppPreparedUpdate, Error>) -> Void) -> () -> Void {
            callbacks.append(completion)
            self.progress.append(progress)
            return { self.cancellations += 1 }
        }
    }

    private static func release(_ version: String = "0.3.0") -> AppRelease {
        AppRelease(version: ReleaseVersion(version)!, url: URL(string: "https://github.com/jokyme/Deskset/releases/tag/v\(version)")!)
    }

    private static func prepared(_ t: AppTestRunner) -> AppPreparedUpdate {
        let root = t.temporaryDirectory("prepared-update")
        return AppPreparedUpdate(directory: root, appURL: root.appendingPathComponent("Deskset.app"))
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Updates: dismissing a download releases activation tracking and keeps Ready reusable") {
            let service = Fetcher(), downloader = Downloader()
            let flow = AppUpdateFlow(presentsWindows: false, service: service, downloader: downloader) { _ in }
            let baseline = AppActivation.trackedCount
            flow.window?.alphaValue = 0
            flow.start(release())
            flow.window?.orderFront(nil)
            AppActivation.track(flow.window)
            t.equal(AppActivation.trackedCount, baseline + 1)
            flow.dismiss()
            t.equal(AppActivation.trackedCount, baseline, "Cancel releases the tracked window")
            flow.start(release())
            service.callbacks[1](.success(release()))
            let payload = prepared(t)
            downloader.callbacks[0](.success(payload))
            flow.window?.orderFront(nil)
            AppActivation.track(flow.window)
            flow.dismiss()
            t.equal(AppActivation.trackedCount, baseline, "Later releases the tracked window")
            t.equal(flow.phase, .ready)
            t.check(FileManager.default.fileExists(atPath: payload.directory.path))
            flow.start(release())
            t.equal(flow.phase, .ready)
            t.equal(service.callbacks.count, 2, "reopening a closed Ready window reuses its verified download")
        }

        t.suite("App: Updates: download flow is cancellable and ignores late callbacks") {
            let service = Fetcher(), downloader = Downloader()
            let flow = AppUpdateFlow(presentsWindows: false, service: service, downloader: downloader) { _ in
                t.check(false, "a cancelled download never installs")
            }
            flow.start(release())
            t.equal(flow.phase, .fetching)
            flow.dismiss()
            t.equal(service.cancellations, 1)
            service.callbacks[0](.success(release()))
            t.equal(downloader.callbacks.count, 0)
            flow.start(release())
            service.callbacks[1](.success(release()))
            t.equal(flow.phase, .downloading)
            downloader.progress[0](0.5)
            t.equal(flow.progress.doubleValue, 0.5)
            downloader.progress[0](nil)
            t.check(flow.progressText.stringValue.contains("Verifying"))
            flow.dismiss()
            t.equal(downloader.cancellations, 1)
            let obsolete = prepared(t)
            downloader.callbacks[0](.success(obsolete))
            t.equal(flow.phase, .idle)
            t.check(!FileManager.default.fileExists(atPath: obsolete.directory.path), "late payload is cleaned")
        }

        t.suite("App: Updates: verified download waits for restart confirmation and survives cancelled quitting") {
            let service = Fetcher(), downloader = Downloader()
            var installs = 0
            let flow = AppUpdateFlow(presentsWindows: false, service: service, downloader: downloader) { _ in installs += 1 }
            flow.start(release())
            service.callbacks[0](.success(release()))
            let payload = prepared(t)
            downloader.callbacks[0](.success(payload))
            t.equal(flow.phase, .ready)
            t.equal(installs, 0, "download completion never quits the app")
            t.equal(flow.primary.title, "Install and Relaunch")
            flow.dismiss()
            t.check(FileManager.default.fileExists(atPath: payload.directory.path), "Later keeps the verified download")
            flow.start(release())
            t.equal(service.callbacks.count, 1, "reopening Ready does not download again")
            flow.performPrimary()
            t.equal(installs, 1)
            t.equal(flow.phase, .preparing)
            t.equal(flow.window?.standardWindowButton(.closeButton)?.isEnabled, false,
                    "the close control reflects the non-cancellable installation preparation")
            flow.dismiss()
            t.equal(flow.phase, .preparing, "do not delete source during handoff preparation")
            flow.installationCancelled()
            t.equal(flow.phase, .ready)
            t.equal(flow.window?.standardWindowButton(.closeButton)?.isEnabled, true)
            t.check(flow.prepared != nil)
            flow.performPrimary()
            t.equal(installs, 2)
            flow.cancelAndCleanUp()
            t.check(!FileManager.default.fileExists(atPath: payload.directory.path))
        }

        t.suite("App: Updates: failed downloads retry and stale cached releases cannot downgrade") {
            let service = Fetcher(), downloader = Downloader()
            let flow = AppUpdateFlow(presentsWindows: false, service: service, downloader: downloader) { _ in }
            flow.start(release())
            service.callbacks[0](.success(release("0.2.0")))
            t.equal(flow.phase, .failed)
            t.equal(downloader.callbacks.count, 0)
            flow.performPrimary()
            service.callbacks[1](.success(release()))
            downloader.callbacks[0](.failure(URLError(.notConnectedToInternet)))
            t.equal(flow.phase, .failed)
            t.equal(flow.primary.title, "Retry")
            t.check(flow.detail.stringValue.contains("has not been changed"))
            flow.performPrimary()
            t.equal(service.callbacks.count, 3)
            flow.cancelAndCleanUp()
        }

        t.suite("App: Updates: Retry refreshes previously supplied download metadata") {
            let service = Fetcher(), downloader = Downloader()
            let cached = release()
            let name = AppUpdateAsset.name(version: cached.version, architecture: AppUpdateAsset.currentArchitecture)
            let asset = AppUpdateAsset(name: name,
                url: URL(string: "https://github.com/jokyme/Deskset/releases/download/v0.3.0/\(name)")!,
                sha256: String(repeating: "0", count: 64), size: 1)
            let flow = AppUpdateFlow(presentsWindows: false, service: service, downloader: downloader) { _ in }
            flow.start(AppRelease(version: cached.version, url: cached.url, assets: [asset]))
            t.equal(service.callbacks.count, 0)
            downloader.callbacks[0](.failure(AppUpdateDownloadError.checksum))
            t.check(!flow.manualDownload.isHidden, "a failed download has an actionable fallback")
            flow.performPrimary()
            t.equal(service.callbacks.count, 1, "Retry fetches a current checksum instead of repeating stale metadata")
            t.equal(downloader.callbacks.count, 1, "wait for the fresh metadata before downloading again")
            flow.cancelAndCleanUp()
        }
    }
}
