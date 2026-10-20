import Foundation
import Darwin

enum AppRestartSelfTests {
    static func run(_ t: AppTestRunner) {
        preparationTests(t)
        cancellationTests(t)
        helperTests(t)
        validationTests(t)
    }

    private static func preparationTests(_ t: AppTestRunner) {
        t.suite("App: Restart: preparation waits for READY without opening or copying the application") {
            let rig = try Rig(t)
            let handoff = try rig.prepare()
            defer { handoff.cancel() }
            t.equal(rig.spawns, 1)
            t.check(rig.opened.isEmpty)
            t.equal(try FileManager.default.contentsOfDirectory(atPath: handoff.directory.path).sorted(),
                    ["manifest.json", "ready.json"])
            t.equal(try FileManager.default.contentsOfDirectory(atPath: rig.apps.path), ["Deskset.app"])
            t.equal(try permissions(handoff.directory), 0o700)
            t.equal(try permissions(handoff.directory.appendingPathComponent("manifest.json")), 0o600)
            try handoff.commit()
            let first = try Data(contentsOf: handoff.directory.appendingPathComponent("commit.json"))
            try handoff.commit()
            t.equal(try Data(contentsOf: handoff.directory.appendingPathComponent("commit.json")), first)
            t.equal(rig.commitWrites, 1)
            t.check(rig.opened.isEmpty, "commit still waits for the parent to exit")
        }
        t.suite("App: Restart: read-only application folders do not prevent preparation") {
            let rig = try Rig(t)
            let directories = [rig.apps, rig.app, rig.app.appendingPathComponent("Contents"),
                               rig.executable.deletingLastPathComponent()]
            for directory in directories { try chmod(directory, 0o555) }
            try chmod(rig.executable, 0o555)
            try chmod(rig.app.appendingPathComponent("Contents/Info.plist"), 0o444)
            defer {
                for directory in directories { try? chmod(directory, 0o755) }
                try? chmod(rig.executable, 0o755)
                try? chmod(rig.app.appendingPathComponent("Contents/Info.plist"), 0o644)
            }
            let handoff = try rig.prepare()
            defer { handoff.cancel() }
            try handoff.commit()
            t.equal(try permissions(rig.apps), 0o555)
            t.equal(try permissions(rig.app), 0o555)
            t.equal(rig.spawns, 1)
        }
        t.suite("App: Restart: failed or late READY stops the helper and leaves no pending job") {
            for failure in ["spawn", "nonce", "pid", "birth", "timeout", "slow-read"] {
                let rig = try Rig(t)
                var dependencies = rig.dependencies()
                let spawn = dependencies.spawn
                dependencies.spawn = { executable, arguments in
                    if failure == "spawn" { throw AppRestart.Failure.helperFailed }
                    let child = try spawn(executable, arguments)
                    let url = URL(fileURLWithPath: arguments[1]).deletingLastPathComponent().appendingPathComponent("ready.json")
                    let ready = try rig.read(AppRestart.Ready.self, url)
                    if failure == "timeout" { try FileManager.default.removeItem(at: url) }
                    else if failure == "nonce" {
                        let old = ready.manifest
                        let manifest = AppRestart.Manifest(job: old.job, nonce: UUID().uuidString, appURL: old.appURL,
                            executableURL: old.executableURL, parentPID: old.parentPID, parentIdentity: old.parentIdentity)
                        try rig.write(AppRestart.Ready(manifest: manifest, helperPID: ready.helperPID,
                                                       helperIdentity: ready.helperIdentity), url)
                    } else if failure == "pid" {
                        try rig.write(AppRestart.Ready(manifest: ready.manifest, helperPID: 99,
                                                       helperIdentity: ready.helperIdentity), url)
                    } else if failure == "birth" { rig.identities[Rig.helperPID] = Rig.identity(99) }
                    return child
                }
                if failure == "slow-read" {
                    dependencies.files.read = { url in
                        let result = try rig.files.read(url)
                        if url.lastPathComponent == "ready.json" { rig.time = 10 }
                        return result
                    }
                }
                do { _ = try rig.prepare(dependencies); t.check(false, "\(failure) must reject preparation") }
                catch { t.check(true) }
                t.equal(rig.stops, failure == "spawn" ? 0 : 1)
                t.equal(try FileManager.default.contentsOfDirectory(atPath: rig.jobs.path), [])
                t.check(rig.opened.isEmpty)
            }
        }
    }

    private static func cancellationTests(_ t: AppTestRunner) {
        t.suite("App: Restart: cancellation revokes both prepared and committed handoffs") {
            for committed in [false, true] {
                let rig = try Rig(t)
                let handoff = try rig.prepare()
                if committed { try handoff.commit() }
                handoff.cancel()
                handoff.cancel()
                t.equal(rig.stops, 1)
                t.check(!FileManager.default.fileExists(atPath: handoff.directory.path))
                do { try handoff.commit(); t.check(false) }
                catch { t.equal(error as? AppRestart.Failure, .cancelled) }
                t.check(rig.opened.isEmpty)
            }
        }
        t.suite("App: Restart: failed commitment cannot authorize a restart") {
            let rig = try Rig(t)
            var dependencies = rig.dependencies()
            dependencies.files.write = { data, url in
                if url.lastPathComponent == "commit.json" { throw CocoaError(.fileWriteNoPermission) }
                try rig.files.write(data, url)
            }
            let handoff = try rig.prepare(dependencies)
            defer { handoff.cancel() }
            do { try handoff.commit(); t.check(false) }
            catch { t.check(true) }
            t.check(!FileManager.default.fileExists(atPath: handoff.directory.appendingPathComponent("commit.json").path))
            t.check(rig.opened.isEmpty)
        }
        t.suite("App: Restart: cancellation still terminates its private child if marker writes fail") {
            let rig = try Rig(t)
            var dependencies = rig.dependencies()
            dependencies.files.write = { data, url in
                if url.lastPathComponent == "cancel.json" { throw CocoaError(.fileWriteNoPermission) }
                try rig.files.write(data, url)
            }
            let handoff = try rig.prepare(dependencies)
            try handoff.commit()
            handoff.cancel()
            t.equal(rig.stops, 1)
            t.check(!FileManager.default.fileExists(atPath: handoff.directory.path))
            t.check(rig.opened.isEmpty)
        }
    }

    private static func helperTests(_ t: AppTestRunner) {
        t.suite("App: Restart: prepared paths round-trip with either application URL directory hint") {
            for isDirectory in [false, true] {
                let rig = try Rig(t)
                let appURL = URL(fileURLWithPath: rig.app.path, isDirectory: isDirectory)
                let handoff = try AppRestart.prepare(appURL: appURL, parentPID: Rig.parentPID,
                                                    dependencies: rig.dependencies())
                defer { handoff.cancel() }
                let manifestURL = handoff.directory.appendingPathComponent("manifest.json")
                let manifest = try rig.read(AppRestart.Manifest.self, manifestURL)
                t.equal(manifest.appURL, rig.app.resolvingSymlinksInPath().standardizedFileURL)
                try handoff.commit()
                rig.onPause = { rig.identities[Rig.parentPID] = nil }
                t.equal(AppRestart.runHelper(manifestURL: manifestURL, nonce: manifest.nonce,
                                            dependencies: rig.helperDependencies()), 0)
                t.equal(rig.opened, [manifest.appURL])
            }
        }
        t.suite("App: Restart: one authorized exit opens exactly once after the parent is gone") {
            let rig = try Rig(t)
            let job = try rig.makeJob()
            rig.onReady = { ready, directory in try rig.write(ready, directory.appendingPathComponent("commit.json")) }
            rig.onPause = { if rig.time >= 0.2 { rig.identities[Rig.parentPID] = nil } }
            var dependencies = rig.helperDependencies()
            dependencies.openApplication = { url in
                t.check(rig.identities[Rig.parentPID] == nil)
                rig.opened.append(url)
            }
            t.equal(AppRestart.runHelper(manifestURL: job.url, nonce: job.manifest.nonce, dependencies: dependencies), 0)
            t.equal(rig.opened, [job.manifest.appURL])
            t.check(rig.time >= 0.2)
            t.check(!FileManager.default.fileExists(atPath: job.url.deletingLastPathComponent().path))
            t.equal(AppRestart.runHelper(manifestURL: job.url, nonce: job.manifest.nonce, dependencies: dependencies), 1)
            t.equal(rig.opened.count, 1, "a consumed job cannot replay")
        }
        t.suite("App: Restart: uncommitted, cancelled, expired and reused parents never open an application") {
            for failure in ["uncommitted", "cancelled", "removed", "timeout", "reused", "slow-identity"] {
                let rig = try Rig(t)
                let job = try rig.makeJob()
                if failure != "uncommitted" {
                    rig.onReady = { ready, directory in try rig.write(ready, directory.appendingPathComponent("commit.json")) }
                }
                rig.onPause = {
                    if failure == "cancelled" {
                        let ready = try rig.read(AppRestart.Ready.self, job.url.deletingLastPathComponent().appendingPathComponent("ready.json"))
                        try rig.write(ready, job.url.deletingLastPathComponent().appendingPathComponent("cancel.json"))
                        rig.identities[Rig.parentPID] = nil
                    } else if failure == "removed" {
                        try FileManager.default.removeItem(at: job.url.deletingLastPathComponent())
                        rig.identities[Rig.parentPID] = nil
                    } else if failure == "reused" { rig.identities[Rig.parentPID] = Rig.identity(99) }
                    else if failure == "timeout" { rig.time = 60 }
                    else { rig.identities[Rig.parentPID] = nil }
                }
                var dependencies = rig.helperDependencies()
                if failure == "slow-identity" {
                    var parentReads = 0
                    dependencies.identity = { pid in
                        if pid == Rig.parentPID {
                            parentReads += 1
                            if parentReads > 1 { rig.time = 60; return nil }
                        }
                        return rig.identities[pid]
                    }
                }
                t.equal(AppRestart.runHelper(manifestURL: job.url, nonce: job.manifest.nonce, dependencies: dependencies), 1)
                t.check(rig.opened.isEmpty, "\(failure) must never relaunch")
            }
        }
        t.suite("App: Restart: the final application validation cannot run beyond the exit deadline") {
            let rig = try Rig(t)
            let job = try rig.makeJob()
            rig.onReady = { ready, directory in try rig.write(ready, directory.appendingPathComponent("commit.json")) }
            rig.onPause = { rig.identities[Rig.parentPID] = nil }
            var dependencies = rig.helperDependencies()
            var validations = 0
            dependencies.validateApplication = { _ in
                validations += 1
                if validations == 2 { rig.time = 60 }
            }
            t.equal(AppRestart.runHelper(manifestURL: job.url, nonce: job.manifest.nonce, dependencies: dependencies), 1)
            t.equal(validations, 2)
            t.check(rig.opened.isEmpty)
        }
        t.suite("App: Restart: launch failure is reported without a fallback or second launch") {
            let rig = try Rig(t)
            let job = try rig.makeJob()
            rig.onReady = { ready, directory in try rig.write(ready, directory.appendingPathComponent("commit.json")) }
            rig.onPause = { rig.identities[Rig.parentPID] = nil }
            var dependencies = rig.helperDependencies()
            dependencies.openApplication = { url in rig.opened.append(url); throw CocoaError(.fileReadNoPermission) }
            t.equal(AppRestart.runHelper(manifestURL: job.url, nonce: job.manifest.nonce, dependencies: dependencies), 1)
            t.equal(rig.opened, [job.manifest.appURL])
        }
    }

    private static func validationTests(_ t: AppTestRunner) {
        t.suite("App: Restart: helper arguments and exact process authorization are required") {
            t.equal(AppRestart.runEarlyIfRequested(["Deskset", "--help"]), nil)
            t.equal(AppRestart.runEarlyIfRequested(["Deskset", AppRestart.argument]), 2)
            t.equal(AppRestart.runEarlyIfRequested(["Deskset", AppRestart.argument, "x", "y", "z"]), 2)
            for failure in ["nonce", "parent", "birth", "executable", "permissions"] {
                let rig = try Rig(t)
                let job = try rig.makeJob()
                var dependencies = rig.helperDependencies()
                if failure == "parent" { dependencies.parentPID = { 99 } }
                if failure == "birth" { rig.identities[Rig.parentPID] = Rig.identity(99) }
                if failure == "executable" { dependencies.currentExecutableURL = { URL(fileURLWithPath: "/different/Deskset") } }
                if failure == "permissions" { try chmod(job.url, 0o644) }
                t.equal(AppRestart.runHelper(manifestURL: job.url,
                    nonce: failure == "nonce" ? UUID().uuidString : job.manifest.nonce, dependencies: dependencies), 1)
                t.check(rig.opened.isEmpty)
                t.check(!FileManager.default.fileExists(atPath: job.url.deletingLastPathComponent().appendingPathComponent("ready.json").path))
            }
        }
        t.suite("App: Restart: private marker reads reject symlinks and commits bind to READY") {
            let rig = try Rig(t)
            let handoff = try rig.prepare()
            defer { handoff.cancel() }
            let marker = handoff.directory.appendingPathComponent("ready.json")
            let original = handoff.directory.appendingPathComponent("saved-ready.json")
            try FileManager.default.moveItem(at: marker, to: original)
            try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: original)
            do { try handoff.commit(); t.check(false) }
            catch { t.check(true) }
            t.check(!FileManager.default.fileExists(atPath: handoff.directory.appendingPathComponent("commit.json").path))
            t.check(rig.opened.isEmpty)
        }
    }

    private static func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    private static func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private final class Rig {
        static let parentPID: pid_t = 41
        static let helperPID: pid_t = 42
        let root: URL
        let apps: URL
        let app: URL
        let executable: URL
        let jobs: URL
        let files = AppRestart.Files()
        var time: TimeInterval = 0
        var spawns = 0
        var stops = 0
        var commitWrites = 0
        var running = true
        var opened: [URL] = []
        var identities = [parentPID: identity(parentPID), helperPID: identity(helperPID)]
        var onReady: ((AppRestart.Ready, URL) throws -> Void)?
        var onPause: (() throws -> Void)?

        init(_ t: AppTestRunner) throws {
            root = t.temporaryDirectory("restart-handoff").resolvingSymlinksInPath()
            apps = root.appendingPathComponent("Applications")
            app = apps.appendingPathComponent("Deskset.app")
            executable = app.appendingPathComponent("Contents/MacOS/Deskset")
            jobs = root.appendingPathComponent("jobs")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: false)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try chmod(executable, 0o755)
            let plist = ["CFBundleIdentifier": AppInstallation.bundleID, "CFBundleExecutable": "Deskset", "CFBundleShortVersionString": "1.0.0"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
        }

        static func identity(_ pid: pid_t) -> AppUpdateInstaller.ProcessIdentity {
            AppUpdateInstaller.ProcessIdentity(seconds: Int64(pid), microseconds: 123)
        }
        func write<T: Encodable>(_ value: T, _ url: URL) throws { try files.write(JSONEncoder().encode(value), url) }
        func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
            guard let data = try files.read(url) else { throw AppRestart.Failure.invalidJob }
            return try JSONDecoder().decode(type, from: data)
        }
        func prepare(_ d: AppRestart.Dependencies? = nil) throws -> AppRestart.Handoff {
            try AppRestart.prepare(appURL: app, parentPID: Self.parentPID, dependencies: d ?? dependencies())
        }
        func makeJob() throws -> (url: URL, manifest: AppRestart.Manifest) {
            let job = UUID().uuidString
            let directory = jobs.appendingPathComponent("DesksetRestart-" + job)
            try files.makeDirectory(directory)
            let manifest = AppRestart.Manifest(job: job, nonce: UUID().uuidString,
                appURL: app.resolvingSymlinksInPath().standardizedFileURL,
                executableURL: executable.resolvingSymlinksInPath().standardizedFileURL,
                parentPID: Self.parentPID, parentIdentity: Self.identity(Self.parentPID))
            let url = directory.appendingPathComponent("manifest.json")
            try write(manifest, url)
            return (url, manifest)
        }
        func dependencies() -> AppRestart.Dependencies {
            var d = AppRestart.Dependencies()
            d.currentAppURL = { self.app }
            d.currentExecutableURL = { self.executable }
            d.pid = { Self.parentPID }
            d.parentPID = { Self.parentPID }
            d.identity = { self.identities[$0] }
            d.now = { self.time }
            d.pause = { delay in self.time += delay; try? self.onPause?() }
            d.temporaryDirectory = { self.jobs }
            d.files = files
            d.files.write = { data, url in
                try self.files.write(data, url)
                if url.lastPathComponent == "commit.json" { self.commitWrites += 1 }
                if url.lastPathComponent == "ready.json" {
                    try self.onReady?(JSONDecoder().decode(AppRestart.Ready.self, from: data), url.deletingLastPathComponent())
                }
            }
            d.spawn = { _, arguments in
                self.spawns += 1
                let manifestURL = URL(fileURLWithPath: arguments[1])
                let manifest = try self.read(AppRestart.Manifest.self, manifestURL)
                try self.write(AppRestart.Ready(manifest: manifest, helperPID: Self.helperPID,
                                               helperIdentity: Self.identity(Self.helperPID)),
                               manifestURL.deletingLastPathComponent().appendingPathComponent("ready.json"))
                return AppRestart.Child(pid: Self.helperPID, isRunning: { self.running }, terminate: {
                    self.stops += 1; self.running = false
                })
            }
            d.openApplication = { self.opened.append($0) }
            return d
        }
        func helperDependencies() -> AppRestart.Dependencies {
            var d = dependencies()
            d.pid = { Self.helperPID }
            return d
        }
    }
}
