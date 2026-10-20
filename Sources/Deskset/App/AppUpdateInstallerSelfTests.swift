import Foundation

enum AppUpdateInstallerSelfTests {
    static func run(_ t: AppTestRunner) {
        waitingTests(t)
        strictWaitingTests(t)
        validationTests(t)
        helperIdentityTests(t)
        handoffTests(t)
    }

    private static func helperIdentityTests(_ t: AppTestRunner) {
        t.suite("App: Update installer: relaunched apps ignore only private update helpers") {
            let fm = FileManager.default
            let temporary = fm.temporaryDirectory.resolvingSymlinksInPath()
            let job = temporary.appendingPathComponent("DesksetUpdate-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: job) }
            try fm.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let helper = try makeApp(job.appendingPathComponent("DesksetUpdater.app"), version: "1.0.0")
            let manifest = job.appendingPathComponent("manifest.json")
            t.check(!AppUpdateInstaller.isHelperApplication(helper), "an ordinary app without the private manifest is not ignored")
            try Data("{}".utf8).write(to: manifest)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            t.check(AppUpdateInstaller.isHelperApplication(helper))
            t.check(!AppUpdateInstaller.isHelperApplication(URL(fileURLWithPath: "/Applications/Deskset.app")))
            t.check(!AppUpdateInstaller.isHelperApplication(temporary.appendingPathComponent("DesksetUpdater.app")))
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path)
            t.check(!AppUpdateInstaller.isHelperApplication(helper), "a nonprivate manifest does not identify a helper")
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: job.path)
            t.check(!AppUpdateInstaller.isHelperApplication(helper), "a nonprivate job does not identify a helper")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: job.path)
            try fm.removeItem(at: job)
            t.check(AppUpdateInstaller.isHelperApplication(helper), "a briefly stale Launch Services entry after helper cleanup is ignored")
        }
    }

    private static func waitingTests(_ t: AppTestRunner) {
        t.suite("App: Update installer: commitment and exact parent exit are both required") {
            let original = AppUpdateInstaller.ProcessIdentity(seconds: 10, microseconds: 20)
            let reused = AppUpdateInstaller.ProcessIdentity(seconds: 11, microseconds: 20)
            let manifest = AppUpdateInstaller.Manifest(destination: URL(fileURLWithPath: "/Applications/Deskset.app"),
                                                       expectedVersion: "1.2.3", parentPID: 123,
                                                       parentIdentity: original)
            var elapsed: TimeInterval = 0
            try AppUpdateInstaller.waitForParentExit(manifest, committed: { elapsed >= 1 },
                                                     identity: { _ in elapsed >= 2 ? nil : original },
                                                     now: { elapsed }, pause: { elapsed += 1 })
            t.equal(elapsed, 2, "commit alone must not begin replacing a running app")
            do {
                try AppUpdateInstaller.waitForParentExit(manifest, committed: { false }, identity: { _ in nil })
                t.check(false, "an uncommitted parent exit never installs")
            } catch { t.check(error is AppUpdateInstaller.Failure) }
            do {
                try AppUpdateInstaller.waitForParentExit(manifest, committed: { true }, identity: { _ in reused })
                t.check(false, "a reused PID must not count as the expected process")
            } catch { t.check(error is AppUpdateInstaller.Failure) }
            elapsed = 0
            do {
                try AppUpdateInstaller.waitForParentExit(manifest, committed: { true }, identity: { _ in original },
                                                         now: { elapsed }, pause: { elapsed += 30 })
                t.check(false, "a parent that never exits must time out")
            } catch { t.equal(elapsed, 60) }
            elapsed = 0
            do {
                try AppUpdateInstaller.waitForParentExit(manifest, committed: { false }, identity: { _ in original },
                                                         now: { elapsed }, pause: { elapsed += 600 })
                t.check(false, "an abandoned uncommitted helper must time out")
            } catch { t.equal(elapsed, 1800) }
            let current = try AppUpdateInstaller.processIdentity(ProcessInfo.processInfo.processIdentifier)
            t.check(current != nil, "the running process has a kernel start timestamp")
            t.equal(try AppUpdateInstaller.processIdentity(ProcessInfo.processInfo.processIdentifier), current)
        }
    }

    private static func validationTests(_ t: AppTestRunner) {
        t.suite("App: Update installer: exact version and destination are verified before handoff") {
            let root = t.temporaryDirectory("update-install-validation").resolvingSymlinksInPath()
            let source = try makeApp(root.appendingPathComponent("Downloaded/Deskset.app"), version: "1.2.3")
            let target = try makeApp(root.appendingPathComponent("Applications/Deskset.app"), version: "1.0.0")
            try AppUpdateInstaller.validateApplications(source: source, destination: target, expectedVersion: "1.2.3")
            t.check(true)
            for (destination, version) in [(source, "1.2.3"), (target, "1.2.4")] {
                do {
                    try AppUpdateInstaller.validateApplications(source: source, destination: destination, expectedVersion: version)
                    t.check(false, "source equality or unexpected downloaded version must fail")
                } catch { t.check(error is AppUpdateInstaller.Failure) }
            }
            let link = root.appendingPathComponent("Linked.app")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            do {
                try AppUpdateInstaller.validateApplications(source: source, destination: link, expectedVersion: "1.2.3")
                t.check(false, "a symlink destination must not be replaced")
            } catch { t.check(error is AppUpdateInstaller.Failure) }
            try makeApp(target, version: "2.0.0")
            do {
                try AppUpdateInstaller.validateApplications(source: source, destination: target, expectedVersion: "1.2.3")
                t.check(false, "a newer app installed while downloading must not be downgraded")
            } catch { t.equal(error as? AppInstallation.Failure, .olderVersion("2.0.0")) }
        }
    }

    private static func strictWaitingTests(_ t: AppTestRunner) {
        t.suite("App: Update installer: expired waits reject late exits and late commitment") {
            let identity = AppUpdateInstaller.ProcessIdentity(seconds: 10, microseconds: 20)
            for scenario in ["exit-at-deadline", "late-commit", "slow-identity", "slow-commit"] {
                var time: TimeInterval = 0
                do {
                    try AppUpdateInstaller.waitForParentExit(parentPID: 123, parentIdentity: identity, committed: {
                        if scenario == "slow-commit" { time = 1800; return true }
                        return scenario == "late-commit" ? time >= 1800 : true
                    }, identity: { _ in
                        if scenario == "slow-identity" { time = 60; return nil }
                        return scenario == "exit-at-deadline" && time >= 60 ? nil : identity
                    }, now: { time }, pause: { time += scenario == "late-commit" ? 1800 : 60 })
                    t.check(false, "\(scenario) cannot succeed after its deadline")
                } catch {
                    if case AppUpdateInstaller.Failure.timedOut = error { t.check(true) }
                    else { t.check(false, "expected a timeout, got \(error)") }
                }
            }
        }
        t.suite("App: Update installer: repeated commitment cannot extend the closing deadline") {
            let identity = AppUpdateInstaller.ProcessIdentity(seconds: 10, microseconds: 20)
            var time: TimeInterval = 0
            do {
                try AppUpdateInstaller.waitForParentExit(parentPID: 123, parentIdentity: identity, committed: { true },
                    identity: { _ in identity }, now: { time }, pause: { time += 20 })
                t.check(false)
            } catch {
                if case AppUpdateInstaller.Failure.timedOut = error { t.check(true) }
                else { t.check(false, "expected a timeout, got \(error)") }
            }
            t.equal(time, 60)
            time = 0
            let deadline = try AppUpdateInstaller.waitForParentExit(parentPID: 123, parentIdentity: identity,
                committed: { true }, identity: { _ in time >= 1 ? nil : identity }, now: { time }, pause: { time += 1 })
            t.equal(deadline, 60, "the caller can check the same deadline after final validation")
        }
    }

    private static func handoffTests(_ t: AppTestRunner) {
        t.suite("App: Update installer: successful replacement relaunches only the installed app") {
            let root = t.temporaryDirectory("update-install-success")
            let source = try makeApp(root.appendingPathComponent("Downloaded/Deskset.app"), version: "1.2.3")
            let target = try makeApp(root.appendingPathComponent("Applications/Deskset.app"), version: "1.0.0")
            var opened: [URL] = []
            var reports = 0
            let result = AppUpdateInstaller.finishInstallation(source: source, destination: target, install: {
                try AppInstallation.install(source: $0, destination: $1, verify: { _ in }, anotherCopyIsRunning: { false })
            }, open: { opened.append($0) }, report: { _, _ in reports += 1 })
            t.equal(result, 0)
            t.equal(opened, [target])
            t.equal(reports, 0)
            t.equal(try AppInstallation.info(at: target).version, "1.2.3")
        }

        t.suite("App: Update installer: failed replacement restores and relaunches the old app") {
            let root = t.temporaryDirectory("update-install-rollback")
            let source = try makeApp(root.appendingPathComponent("Downloaded/Deskset.app"), version: "1.2.3")
            let target = try makeApp(root.appendingPathComponent("Applications/Deskset.app"), version: "1.0.0")
            var events: [String] = []
            let result = AppUpdateInstaller.finishInstallation(source: source, destination: target, install: {
                try AppInstallation.install(source: $0, destination: $1, verify: { _ in }, replace: { old, staged, backup in
                    try FileManager.default.moveItem(at: old, to: old.deletingLastPathComponent().appendingPathComponent(backup))
                    try FileManager.default.moveItem(at: staged, to: old)
                    throw CocoaError(.fileWriteNoPermission)
                }, anotherCopyIsRunning: { false })
            }, open: {
                t.equal($0, target)
                t.equal(try AppInstallation.info(at: $0).version, "1.0.0", "only the restored old app is launched")
                events.append("open")
            }, report: { _, _ in events.append("report") })
            t.equal(result, 1)
            t.equal(events, ["report", "open"], "a visible failure precedes relaunch of the restored app")
            t.equal(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["Deskset.app"])
        }

        t.suite("App: Update installer: relaunch errors remain visible without reverting a valid update") {
            let root = t.temporaryDirectory("update-install-open-failure")
            let source = try makeApp(root.appendingPathComponent("Downloaded/Deskset.app"), version: "1.2.3")
            let target = try makeApp(root.appendingPathComponent("Applications/Deskset.app"), version: "1.0.0")
            var reports = 0
            let result = AppUpdateInstaller.finishInstallation(source: source, destination: target, install: {
                try AppInstallation.install(source: $0, destination: $1, verify: { _ in }, anotherCopyIsRunning: { false })
            }, open: { _ in throw CocoaError(.fileReadNoPermission) }, report: { _, _ in reports += 1 })
            t.equal(result, 1)
            t.equal(reports, 1)
            t.equal(try AppInstallation.info(at: target).version, "1.2.3")
        }
    }

    @discardableResult
    private static func makeApp(_ url: URL, version: String) throws -> URL {
        let executable = url.appendingPathComponent("Contents/MacOS/Deskset")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = ["CFBundleIdentifier": AppInstallation.bundleID, "CFBundleExecutable": "Deskset",
                     "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }
}
