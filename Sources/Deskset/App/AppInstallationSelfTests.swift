import Foundation

/// Uses temporary fake application bundles and injected copy/signature/running checks; never opens or quits apps.
enum AppInstallationSelfTests {
    static func run(_ t: AppTestRunner) {
        detectionTests(t)
        destinationTests(t)
        installTests(t)
    }

    private static func detectionTests(_ t: AppTestRunner) {
        t.suite("App: Installation: only read-only disk-image app launches prompt") {
            let volume = URL(fileURLWithPath: "/Volumes/Deskset 1.2.3", isDirectory: true)
            let app = volume.appendingPathComponent("Deskset.app")
            t.check(AppInstallation.needsInstallation(bundle: app, volume: volume, readOnly: true))
            t.check(!AppInstallation.needsInstallation(bundle: app, volume: volume, readOnly: false))
            t.check(!AppInstallation.needsInstallation(bundle: app, volume: nil, readOnly: true))
            t.check(!AppInstallation.needsInstallation(bundle: URL(fileURLWithPath: "/Applications/Deskset.app"),
                                                       volume: URL(fileURLWithPath: "/"), readOnly: false))
            t.check(!AppInstallation.needsInstallation(bundle: URL(fileURLWithPath: "/tmp/.build/debug/Deskset"),
                                                       volume: volume, readOnly: true))
            t.check(!AppInstallation.needsInstallation(bundle: URL(fileURLWithPath: "/Volumes/Deskset 1.2.30/Deskset.app"),
                                                       volume: volume, readOnly: true), "volume names use a path boundary")
            let translocated = URL(fileURLWithPath: "/private/tmp/AppTranslocation/token/d/Deskset.app")
            t.check(!AppInstallation.needsInstallation(bundle: translocated, volume: translocated.deletingLastPathComponent(),
                                                       readOnly: true), "unknown read-only locations use manual installation")
        }
    }

    private static func destinationTests(_ t: AppTestRunner) {
        t.suite("App: Installation: destination respects existing copies and permissions") {
            let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let user = URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)
            let systemApp = system.appendingPathComponent("Deskset.app", isDirectory: true)
            let userApp = user.appendingPathComponent("Deskset.app", isDirectory: true)
            func choose(existing: Set<String> = [], writable: Set<String>) throws -> URL {
                try AppInstallation.destination(system: system, user: user,
                                                exists: { existing.contains($0.path) }, writable: { writable.contains($0.path) })
            }
            t.equal(try choose(writable: [system.path]), systemApp)
            t.equal(try choose(writable: [user.deletingLastPathComponent().path]), userApp, "first install can use ~/Applications")
            t.equal(try choose(existing: [user.path, userApp.path], writable: [system.path, user.path, userApp.path]), userApp,
                    "an existing user installation is upgraded where it is")
            do {
                _ = try choose(existing: [systemApp.path], writable: [user.path, user.deletingLastPathComponent().path])
                t.check(false, "must not bypass an unwritable existing installation")
            } catch { t.equal(error as? AppInstallation.Failure, .notWritable(systemApp)) }
        }
    }

    @discardableResult
    private static func makeApp(_ url: URL, version: String, bundleID: String = AppInstallation.bundleID) throws -> URL {
        let fm = FileManager.default
        let executable = url.appendingPathComponent("Contents/MacOS/Deskset")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Deskset", "CFBundleShortVersionString": version]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    private static func installTests(_ t: AppTestRunner) {
        t.suite("App: Installation: complete verified copies install and replace") {
            let root = t.temporaryDirectory("app-install")
            let source = try makeApp(root.appendingPathComponent("Source/Deskset.app"), version: "1.2.3")
            let destination = root.appendingPathComponent("Applications/Deskset.app")
            var verified = 0
            let verify: (URL) throws -> Void = { staged in
                verified += 1
                t.equal(staged.deletingLastPathComponent().deletingLastPathComponent(), destination.deletingLastPathComponent(),
                        "staging is in the destination directory")
                t.equal(try AppInstallation.info(at: staged).version, "1.2.3")
            }
            try AppInstallation.install(source: source, destination: destination, verify: verify, anotherCopyIsRunning: { false })
            t.equal(try AppInstallation.info(at: destination).version, "1.2.3")
            t.equal(verified, 1)
            try makeApp(destination, version: "1.0.0")
            try Data("old".utf8).write(to: destination.appendingPathComponent("old-only.txt"))
            try AppInstallation.install(source: source, destination: destination, verify: verify, anotherCopyIsRunning: { false })
            t.equal(try AppInstallation.info(at: destination).version, "1.2.3")
            t.check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("old-only.txt").path))
            t.equal(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["Deskset.app"])
        }

        t.suite("App: Installation: older and invalid applications never replace the installed copy") {
            let root = t.temporaryDirectory("app-install-version")
            let source = try makeApp(root.appendingPathComponent("Source/Deskset.app"), version: "1.0.0")
            let destination = try makeApp(root.appendingPathComponent("Applications/Deskset.app"), version: "2.0.0")
            var copied = false
            do {
                try AppInstallation.install(source: source, destination: destination, copy: { _, _ in copied = true },
                                            verify: { _ in }, anotherCopyIsRunning: { false })
                t.check(false, "downgrade refused")
            } catch { t.equal(error as? AppInstallation.Failure, .olderVersion("2.0.0")) }
            t.check(!copied)
            t.equal(try AppInstallation.info(at: destination).version, "2.0.0")
            do {
                try AppInstallation.install(source: destination, destination: destination, verify: { _ in }, anotherCopyIsRunning: { false })
                t.check(false, "source and destination must differ")
            } catch { t.equal(error as? AppInstallation.Failure, .invalidApp) }
            try makeApp(source, version: "3.0.0", bundleID: "com.example.OtherApp")
            do { _ = try AppInstallation.info(at: source); t.check(false, "foreign bundle refused") }
            catch { t.equal(error as? AppInstallation.Failure, .invalidApp) }
            try AppInstallation.checkVersion(source: .init(version: "2.0.0"), installed: .init(version: "2.0.0-beta.1"))
            do {
                try AppInstallation.checkVersion(source: .init(version: "2.0.0-beta.1"), installed: .init(version: "2.0.0"))
                t.check(false, "prerelease must not downgrade stable")
            } catch { t.equal(error as? AppInstallation.Failure, .olderVersion("2.0.0")) }
        }

        t.suite("App: Installation: copy and signature failures preserve the installed application") {
            let root = t.temporaryDirectory("app-install-copy-failure")
            let source = try makeApp(root.appendingPathComponent("Source/Deskset.app"), version: "2.0.0")
            let destination = try makeApp(root.appendingPathComponent("Applications/Deskset.app"), version: "1.0.0")
            do {
                try AppInstallation.install(source: source, destination: destination, copy: { original, staged in
                    try FileManager.default.copyItem(at: original, to: staged)
                    throw CocoaError(.fileWriteOutOfSpace)
                }, verify: { _ in }, anotherCopyIsRunning: { false })
                t.check(false, "copy failure reported")
            } catch { t.equal((error as? CocoaError)?.code, .fileWriteOutOfSpace) }
            t.equal(try AppInstallation.info(at: destination).version, "1.0.0")
            do {
                try AppInstallation.install(source: source, destination: destination, verify: { _ in throw AppInstallation.Failure.signature },
                                            anotherCopyIsRunning: { false })
                t.check(false, "signature failure reported")
            } catch { t.equal(error as? AppInstallation.Failure, .signature) }
            t.equal(try AppInstallation.info(at: destination).version, "1.0.0")
            t.equal(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["Deskset.app"])
        }

        t.suite("App: Installation: failed replacement restores its backup") {
            let root = t.temporaryDirectory("app-install-rollback")
            let source = try makeApp(root.appendingPathComponent("Source/Deskset.app"), version: "2.0.0")
            let destination = try makeApp(root.appendingPathComponent("Applications/Deskset.app"), version: "1.0.0")
            for newCopyWasMoved in [false, true] {
                do {
                    try AppInstallation.install(source: source, destination: destination, verify: { _ in }, replace: { old, staged, backup in
                        try FileManager.default.moveItem(at: old, to: old.deletingLastPathComponent().appendingPathComponent(backup))
                        if newCopyWasMoved { try FileManager.default.moveItem(at: staged, to: old) }
                        throw CocoaError(.fileWriteNoPermission)
                    }, anotherCopyIsRunning: { false })
                    t.check(false, "replacement failure reported")
                } catch { t.equal((error as? CocoaError)?.code, .fileWriteNoPermission) }
                t.equal(try AppInstallation.info(at: destination).version, "1.0.0")
                t.equal(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["Deskset.app"])
            }
        }

        t.suite("App: Installation: a copy launched during staging prevents replacement") {
            let root = t.temporaryDirectory("app-install-running")
            let source = try makeApp(root.appendingPathComponent("Source/Deskset.app"), version: "2.0.0")
            let destination = try makeApp(root.appendingPathComponent("Applications/Deskset.app"), version: "1.0.0")
            var checks = 0
            do {
                try AppInstallation.install(source: source, destination: destination, verify: { _ in }, anotherCopyIsRunning: {
                    checks += 1
                    return checks > 1
                })
                t.check(false, "running copy blocks replacement")
            } catch { t.equal(error as? AppInstallation.Failure, .running) }
            t.equal(checks, 2)
            t.equal(try AppInstallation.info(at: destination).version, "1.0.0")
        }
    }
}
