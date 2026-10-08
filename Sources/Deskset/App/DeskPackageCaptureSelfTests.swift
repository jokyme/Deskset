import Foundation
import Darwin
import DeskLanguage

/// Real private scratch folders exercise the same FD capture used by callers; no App/window is launched.
enum DeskPackageCaptureSelfTests {
    private enum FixtureFailure: Error { case setup }
    private enum Rejection {
        case changed, unsupported, resourceLimit, cancelled, ambiguous, invalidRoot
        case invalidName(String)
        case unreadable(Int32)
    }

    private final class DescriptorAudit {
        private var active = Set<Int32>()
        private var opened = 0
        private var closed = 0
        private var problems: [String] = []

        func record(_ checkpoint: DeskPackageCapture.Checkpoint) {
            switch checkpoint {
            case .openedDescriptor(let fd):
                opened += 1
                if !active.insert(fd).inserted { problems.append("descriptor \(fd) opened twice without closing") }
                if fcntl(fd, F_GETFD) < 0 { problems.append("opened descriptor \(fd) is not live") }
            case .closedDescriptor(let fd):
                closed += 1
                if active.remove(fd) == nil { problems.append("descriptor \(fd) closed without an open receipt") }
                errno = 0
                if fcntl(fd, F_GETFD) != -1 || errno != EBADF { problems.append("closed descriptor \(fd) is still live") }
            default: break
            }
        }

        func check(_ t: AppTestRunner, _ label: String, line: UInt = #line) {
            t.check(active.isEmpty, "\(label): capture retained descriptors \(active)", line: line)
            t.equal(opened, closed, "\(label): each acquired descriptor is released", line: line)
            t.equal(problems, [], "\(label): \(problems)", line: line)
        }
    }

    private static func write(_ bytes: Data, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    private static func directory(_ path: String, in root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    private static func entries(_ source: InMemoryPackageSource) throws -> [PackageEntry] {
        var result: [PackageEntry] = []
        try source.walk { result.append($0); return .next }
        return result
    }

    /// Independent POSIX spelling oracle: Swift String equality alone merges NFC/NFD names.
    private static func rawNames(_ root: URL) throws -> [String] {
        guard let stream = opendir(root.path) else { throw FixtureFailure.setup }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw FixtureFailure.setup }
                break
            }
            let count = Int(entry.pointee.d_namlen)
            let bytes = withUnsafePointer(to: &entry.pointee.d_name) {
                Array(UnsafeRawBufferPointer(start: $0, count: count))
            }
            guard let name = String(bytes: bytes, encoding: .utf8) else { throw FixtureFailure.setup }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted(by: DeskPackagePath.precedes)
    }

    private static func rejects(_ t: AppTestRunner, _ expected: Rejection, line: UInt = #line,
                                _ operation: () throws -> Void) {
        do {
            try operation()
            t.check(false, "capture unexpectedly succeeded", line: line)
        } catch let failure as DeskPackageCapture.Failure {
            let matches: Bool
            switch (expected, failure) {
            case (.changed, .changed(_)), (.unsupported, .unsupported(_)), (.resourceLimit, .resourceLimit),
                 (.cancelled, .cancelled), (.ambiguous, .ambiguous(_, _)), (.invalidRoot, .invalidRoot): matches = true
            case (.unreadable(let code), .unreadable(_, let actual)): matches = code == actual
            case (.invalidName(let path), .invalidName(let actual)): matches = DeskPackagePath.sameBytes(path, actual)
            default: matches = false
            }
            t.check(matches, "unexpected capture failure: \(failure)", line: line)
        } catch {
            t.check(false, "unexpected error type: \(error)", line: line)
        }
    }

    private static func simple(_ t: AppTestRunner, _ name: String) throws -> URL {
        let root = t.temporaryDirectory(name)
        try write(Data("source".utf8), "Widget.desk", in: root)
        try write(Data([1, 2, 3, 4]), "assets/unused.bin", in: root)
        try directory("empty", in: root)
        return root
    }

    static func run(_ t: AppTestRunner) {
        contentTests(t)
        budgetTests(t)
        unchangedTests(t)
        identityTests(t)
        noFollowTests(t)
        raceTests(t)
        cancellationTests(t)
        nameTests(t)
    }

    private static func contentTests(_ t: AppTestRunner) {
        t.suite("App: Desk package capture: complete immutable bytes include unused assets and empty directories but exclude ignored trees") {
            let root = t.temporaryDirectory("desk-package-capture-complete")
            let first = Data("\u{FEFF}info { name: \"甲😀\" }\r\nwidget { Text(\"甲😀\") }\r\n".utf8)
            let second = Data("info { name: \"B\" }\nwidget { Text(\"B\") }\n".utf8)
            let packageText = Data("style base { .color(.red) }\r\n".utf8)
            let files: [(String, Data)] = [
                ("A.desk", first), ("B.desk", second), ("package.desk", packageText),
                ("images/used.png", Data([137, 80, 78, 71, 0, 255])),
                ("images/unused.jpg", Data([255, 216, 0, 255])),
                ("fonts/纸😀.ttf", Data([0, 1, 0, 0, 255])),
                ("README.bin", Data([0, 255, 127])),
                ("Nested/Extra.desk", Data("widget { Text(\"not a root member\") }".utf8)),
                ("zero.dat", Data())
            ]
            for (path, bytes) in files { try write(bytes, path, in: root) }
            try directory("Empty/AlsoEmpty", in: root)
            try write(Data(repeating: 99, count: 512), ".DS_Store", in: root)
            try write(Data(repeating: 99, count: 512), ".hidden/private.bin", in: root)
            try write(Data(repeating: 99, count: 512), "__MACOSX/private.bin", in: root)
            let ignoredLink = root.appendingPathComponent(".hidden/no-follow")
            try FileManager.default.createSymbolicLink(at: ignoredLink, withDestinationURL: root)
            let ignoredFIFO = root.appendingPathComponent("__MACOSX/pipe")
            guard mkfifo(ignoredFIFO.path, 0o600) == 0 else { throw FixtureFailure.setup }

            var limits = DeskCatalog.current.limits
            limits.maximumPackageFiles = files.count
            limits.maximumPackageBytes = files.reduce(0) { $0 + $1.1.count }
            let audit = DescriptorAudit()
            let capture = try DeskPackageCapture.read(root: root, limits: limits, hooks: .init(at: audit.record))
            t.equal(capture.files.map(\.path), files.map(\.0).sorted(by: DeskPackagePath.precedes))
            t.equal(capture.totalBytes, limits.maximumPackageBytes, "ignored bytes do not consume the exact payload budget")
            t.equal(capture.rootIdentity.kind, .directory)
            t.equal(Set(capture.directories.map(\.path)), Set(["", "Empty", "Empty/AlsoEmpty", "Nested", "fonts", "images"]))
            for (path, bytes) in files {
                t.equal(try capture.source.read(path, limit: bytes.count + 1), bytes, path)
                t.equal(capture.files.first { DeskPackagePath.sameBytes($0.path, path) }?.bytes, bytes)
            }
            let sourceEntries = try entries(capture.source)
            t.check(sourceEntries.allSatisfy { entry in !entry.path.split(separator: "/").contains { DeskPackagePath.isIgnoredName(String($0)) } })
            t.equal(sourceEntries.filter { $0.type == .directory }.map(\.path).sorted(by: DeskPackagePath.precedes),
                    ["Empty", "Empty/AlsoEmpty", "Nested", "fonts", "images"])
            let loaded = try PackageLoader.load(capture.source)
            t.equal(loaded.widgetFiles.map(\.path), ["A.desk", "B.desk"], "nested Desk source is retained but is not promoted to a widget")
            t.equal(loaded.texts[DeskFileID("A.desk")].map { Data($0.utf8) }, first)
            t.equal(loaded.files(.font).map(\.path), ["fonts/纸😀.ttf"])
            t.equal(loaded.files(.image).count, 2, "unreferenced images are retained rather than curated away")
            try capture.validateUnchanged(hooks: .init(at: audit.record))
            audit.check(t, "successful capture and unchanged validation")

            let frozen = capture.source
            try write(Data(repeating: 32, count: first.count), "A.desk", in: root)
            t.equal(try frozen.read("A.desk", limit: first.count + 1), first, "the source is owned bytes, not a mapping of the mutable disk")
            rejects(t, .changed) { try capture.validateUnchanged() }
        }
    }

    private static func budgetTests(_ t: AppTestRunner) {
        t.suite("App: Desk package capture: exact file and byte limits count zero bytes and hard-link names while large assets are legal") {
            let root = t.temporaryDirectory("desk-package-capture-budget")
            try write(Data(), "zero.bin", in: root)
            try write(Data([1]), "one.bin", in: root)
            try write(Data([2, 3, 4]), "three.bin", in: root)
            try directory("empty/deeper", in: root)
            var limits = DeskCatalog.current.limits
            limits.maximumPackageFiles = 3; limits.maximumPackageBytes = 4
            let audit = DescriptorAudit()
            let capture = try DeskPackageCapture.read(root: root, limits: limits, hooks: .init(at: audit.record))
            t.equal(capture.files.count, 3)
            t.equal(capture.totalBytes, 4)
            t.equal(try capture.source.read("zero.bin", limit: 1), Data())
            limits.maximumPackageFiles = 2
            var attemptedReads = 0
            let budgetHooks = DeskPackageCapture.Hooks(at: { checkpoint in
                audit.record(checkpoint)
                if case .willReadFile = checkpoint { attemptedReads += 1 }
            })
            rejects(t, .resourceLimit) { _ = try DeskPackageCapture.read(root: root, limits: limits, hooks: budgetHooks) }
            limits.maximumPackageFiles = 3; limits.maximumPackageBytes = 3
            rejects(t, .resourceLimit) { _ = try DeskPackageCapture.read(root: root, limits: limits, hooks: budgetHooks) }
            t.equal(attemptedReads, 0, "manifest budgets are checked before any payload read")
            for negativeFiles in [true, false] {
                var invalidLimits = DeskCatalog.current.limits
                if negativeFiles { invalidLimits.maximumPackageFiles = -1 }
                else { invalidLimits.maximumPackageBytes = -1 }
                rejects(t, .resourceLimit) { _ = try DeskPackageCapture.read(root: root, limits: invalidLimits, hooks: budgetHooks) }
            }
            t.equal(attemptedReads, 0, "negative limits never start payload reading")
            audit.check(t, "budget failures")

            let sparseRoot = t.temporaryDirectory("desk-package-capture-global-limit")
            let sparse = sparseRoot.appendingPathComponent("unused-sparse.asset")
            let hardLimit = DeskCatalog.current.limits.maximumPackageBytes
            do {
                let fd = Darwin.open(sparse.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw FixtureFailure.setup }
                defer { Darwin.close(fd) }
                guard ftruncate(fd, off_t(hardLimit + 1)) == 0 else { throw FixtureFailure.setup }
            }
            var generousLimits = DeskCatalog.current.limits
            generousLimits.maximumPackageBytes = hardLimit + 1_048_576
            generousLimits.maximumPackageFiles += 1
            let sparseAudit = DescriptorAudit()
            var sparseReads = 0
            rejects(t, .resourceLimit) {
                _ = try DeskPackageCapture.read(root: sparseRoot, limits: generousLimits, hooks: .init(at: { checkpoint in
                    sparseAudit.record(checkpoint)
                    if case .willReadFile = checkpoint { sparseReads += 1 }
                }))
            }
            t.equal(sparseReads, 0, "larger caller limits cannot allocate a payload beyond the global 100 MiB cap")
            sparseAudit.check(t, "global sparse-file budget")

            let largeRoot = t.temporaryDirectory("desk-package-capture-large-asset")
            let large = Data(repeating: 0xA5, count: DeskCatalog.current.limits.maximumFileBytes + 1)
            try write(large, "unreferenced.asset", in: largeRoot)
            let asset = try DeskPackageCapture.read(root: largeRoot)
            t.equal(asset.totalBytes, large.count)
            t.equal(try asset.source.read("unreferenced.asset", limit: large.count + 1), large,
                    "the Desk text limit is not a per-asset limit")

            let links = t.temporaryDirectory("desk-package-capture-hardlinks")
            try write(Data([1, 2, 3]), "first.bin", in: links)
            guard Darwin.link(links.appendingPathComponent("first.bin").path,
                              links.appendingPathComponent("second.bin").path) == 0 else { throw FixtureFailure.setup }
            let linked = try DeskPackageCapture.read(root: links)
            t.equal(linked.files.count, 2)
            t.equal(linked.totalBytes, 6, "two shareable names count twice even when their inode is the same")
            t.equal(linked.files[0].identity.inode, linked.files[1].identity.inode)
            limits.maximumPackageFiles = 2; limits.maximumPackageBytes = 5
            rejects(t, .resourceLimit) { _ = try DeskPackageCapture.read(root: links, limits: limits) }
        }
    }

    private static func unchangedTests(_ t: AppTestRunner) {
        t.suite("App: Desk package capture: freshness rejects new deleted replaced and same-size unreferenced members") {
            for mutation in ["add", "delete", "same-size", "replace", "empty-directory-add"] {
                let root = try simple(t, "desk-package-capture-" + mutation)
                let audit = DescriptorAudit()
                let capture = try DeskPackageCapture.read(root: root, hooks: .init(at: audit.record))
                let member = root.appendingPathComponent("assets/unused.bin")
                switch mutation {
                case "add": try write(Data([9]), "not-referenced.bin", in: root)
                case "delete": try FileManager.default.removeItem(at: member)
                case "same-size": try Data([4, 3, 2, 1]).write(to: member)
                case "replace":
                    let held = t.temporaryDirectory("desk-package-capture-held-member").appendingPathComponent("unused.bin")
                    try FileManager.default.moveItem(at: member, to: held)
                    try write(Data([1, 2, 3, 4]), "assets/unused.bin", in: root)
                default: try write(Data(), "empty/new-zero.bin", in: root)
                }
                rejects(t, .changed) { try capture.validateUnchanged(hooks: .init(at: audit.record)) }
                t.equal(try capture.source.read("assets/unused.bin", limit: 5), Data([1, 2, 3, 4]), mutation)
                audit.check(t, mutation)
            }
        }
    }

    private static func identityTests(_ t: AppTestRunner) {
        t.suite("App: Desk package capture: replacing a directory or root never adopts the foreign named location") {
            for replaceRoot in [false, true] {
                let parent = t.temporaryDirectory("desk-package-capture-identity")
                let root = parent.appendingPathComponent("Package")
                try directory("assets", in: root)
                try write(Data([1, 2, 3, 4]), "assets/unused.bin", in: root)
                let audit = DescriptorAudit()
                let capture = try DeskPackageCapture.read(root: root, hooks: .init(at: audit.record))
                let target = replaceRoot ? root : root.appendingPathComponent("assets")
                let held = parent.appendingPathComponent("Held")
                try FileManager.default.moveItem(at: target, to: held)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let marker = Data("foreign named directory must survive".utf8)
                try marker.write(to: target.appendingPathComponent("sentinel.bin"))
                rejects(t, .changed) { try capture.validateUnchanged(hooks: .init(at: audit.record)) }
                t.equal(try Data(contentsOf: target.appendingPathComponent("sentinel.bin")), marker)
                t.equal(try Data(contentsOf: held.appendingPathComponent(replaceRoot ? "assets/unused.bin" : "unused.bin")), Data([1, 2, 3, 4]))
                t.equal(try capture.source.read("assets/unused.bin", limit: 5), Data([1, 2, 3, 4]))
                audit.check(t, replaceRoot ? "root replacement" : "directory replacement")
            }
        }
    }

    private static func noFollowTests(_ t: AppTestRunner) {
        t.suite("App: Desk package capture: root child links and FIFO members reject without following or blocking") {
            let outside = t.temporaryDirectory("desk-package-capture-outside")
            let marker = Data("external sentinel".utf8)
            try write(marker, "sentinel.bin", in: outside)
            for kind in ["file-link", "directory-link", "fifo"] {
                let root = t.temporaryDirectory("desk-package-capture-nofollow-" + kind)
                try write(Data("source".utf8), "Widget.desk", in: root)
                let entry = root.appendingPathComponent(kind == "directory-link" ? "assets" : "member.bin")
                if kind == "fifo" {
                    guard mkfifo(entry.path, 0o600) == 0 else { throw FixtureFailure.setup }
                } else {
                    try FileManager.default.createSymbolicLink(at: entry,
                        withDestinationURL: kind == "directory-link" ? outside : outside.appendingPathComponent("sentinel.bin"))
                }
                let audit = DescriptorAudit()
                var payloadReads: [String] = []
                rejects(t, .unsupported) {
                    _ = try DeskPackageCapture.read(root: root, hooks: .init(at: { checkpoint in
                        audit.record(checkpoint)
                        if case .willReadFile(let path) = checkpoint { payloadReads.append(path) }
                    }))
                }
                t.equal(payloadReads, [], "unsupported manifest nodes fail before regular payload reading")
                t.equal(try Data(contentsOf: outside.appendingPathComponent("sentinel.bin")), marker)
                audit.check(t, kind)
            }
            let parent = t.temporaryDirectory("desk-package-capture-root-link")
            let link = parent.appendingPathComponent("Package")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            rejects(t, .invalidRoot) { _ = try DeskPackageCapture.read(root: link) }
            rejects(t, .invalidRoot) { _ = try DeskPackageCapture.read(root: URL(string: "https://example.invalid/package")!) }
            t.equal(try Data(contentsOf: outside.appendingPathComponent("sentinel.bin")), marker)
        }
    }

    private static func raceTests(_ t: AppTestRunner) {
        t.suite("App: Desk package capture: deterministic manifest read and final verification races never publish partial bytes") {
            for mutation in ["before-read", "after-read", "before-verify", "directory-swap"] {
                let root = try simple(t, "desk-package-capture-race-" + mutation)
                let audit = DescriptorAudit()
                var fired = false
                var hookError: Error?
                let hooks = DeskPackageCapture.Hooks(at: { checkpoint in
                    audit.record(checkpoint)
                    let shouldFire: Bool
                    switch (mutation, checkpoint) {
                    case ("before-read", .didCaptureManifest), ("directory-swap", .didCaptureManifest),
                         ("after-read", .didReadFile("assets/unused.bin")), ("before-verify", .willVerifyManifest): shouldFire = true
                    default: shouldFire = false
                    }
                    guard shouldFire, !fired else { return }
                    fired = true
                    do {
                        if mutation == "directory-swap" {
                            let assets = root.appendingPathComponent("assets")
                            try FileManager.default.moveItem(at: assets, to: root.appendingPathComponent("held-assets"))
                            try directory("assets", in: root)
                            try write(Data([1, 2, 3, 4]), "assets/unused.bin", in: root)
                        } else if mutation == "before-verify" {
                            try write(Data(), "empty/new.bin", in: root)
                        } else {
                            try write(Data([9, 8, 7, 6]), "assets/unused.bin", in: root)
                        }
                    } catch { hookError = error }
                })
                rejects(t, .changed) { _ = try DeskPackageCapture.read(root: root, hooks: hooks) }
                t.check(fired, "the actual \(mutation) production checkpoint was reached")
                t.check(hookError == nil, "the fixture mutation succeeded: \(String(describing: hookError))")
                audit.check(t, mutation)
            }

            let stable = try simple(t, "desk-package-capture-stable-hooks")
            let audit = DescriptorAudit()
            var phases: [String] = []
            let capture = try DeskPackageCapture.read(root: stable, hooks: .init(at: { checkpoint in
                audit.record(checkpoint)
                switch checkpoint {
                case .didCaptureManifest: phases.append("manifest")
                case .willReadFile(let path): phases.append("read:" + path)
                case .willVerifyManifest: phases.append("verify")
                default: break
                }
            }))
            t.equal(phases, ["manifest", "read:Widget.desk", "read:assets/unused.bin", "verify"])
            try capture.validateUnchanged(hooks: .init(at: audit.record))
            audit.check(t, "stable M0/read/M1")

            for mutation in ["grow-during-read", "truncate-during-read"] {
                let root = t.temporaryDirectory("desk-package-capture-" + mutation)
                let file = root.appendingPathComponent("large.asset")
                try write(Data(repeating: 0xB3, count: 131_073), "large.asset", in: root)
                let audit = DescriptorAudit()
                var fired = false
                var verifiedManifest = false
                var hookError: Error?
                let hooks = DeskPackageCapture.Hooks(at: { checkpoint in
                    audit.record(checkpoint)
                    if case .willVerifyManifest = checkpoint { verifiedManifest = true }
                    guard case .willReadChunk(let path, let offset) = checkpoint,
                          path == "large.asset", offset > 0, !fired else { return }
                    fired = true
                    do {
                        let flags = O_WRONLY | O_CLOEXEC | O_NOFOLLOW | (mutation == "grow-during-read" ? O_APPEND : 0)
                        let fd = Darwin.open(file.path, flags)
                        guard fd >= 0 else { throw FixtureFailure.setup }
                        defer { Darwin.close(fd) }
                        if mutation == "grow-during-read" {
                            var extra: UInt8 = 0xD4
                            guard withUnsafePointer(to: &extra, { Darwin.write(fd, $0, 1) }) == 1 else { throw FixtureFailure.setup }
                        } else {
                            guard ftruncate(fd, off_t(offset)) == 0 else { throw FixtureFailure.setup }
                        }
                    } catch { hookError = error }
                })
                rejects(t, .changed) { _ = try DeskPackageCapture.read(root: root, hooks: hooks) }
                t.check(fired, "the real second chunk boundary changed the still-open source")
                t.check(hookError == nil, "the mutation succeeded: \(String(describing: hookError))")
                t.check(!verifiedManifest, "the bounded file read itself detects \(mutation), before M1")
                audit.check(t, mutation)
            }
        }
    }

    private static func cancellationTests(_ t: AppTestRunner) {
        t.suite("App: Desk package capture: cancellation read interruption and directory errors release every descriptor") {
            let root = try simple(t, "desk-package-capture-cancel")
            try write(Data(repeating: 0xB3, count: 131_073), "large.asset", in: root)
            for phase in ["before-start", "manifest", "chunk", "verify"] {
                let audit = DescriptorAudit()
                var cancelled = phase == "before-start"
                let hooks = DeskPackageCapture.Hooks(at: { checkpoint in
                    audit.record(checkpoint)
                    switch (phase, checkpoint) {
                    case ("manifest", .didCaptureManifest), ("verify", .willVerifyManifest): cancelled = true
                    case ("chunk", .willReadChunk(let path, let offset)) where path == "large.asset" && offset > 0: cancelled = true
                    default: break
                    }
                })
                rejects(t, .cancelled) { _ = try DeskPackageCapture.read(root: root, isCancelled: { cancelled }, hooks: hooks) }
                t.check(cancelled, "the actual \(phase) checkpoint canceled the request")
                audit.check(t, phase)
            }
            let capture = try DeskPackageCapture.read(root: root)
            let validationAudit = DescriptorAudit()
            rejects(t, .cancelled) { try capture.validateUnchanged(isCancelled: { true }, hooks: .init(at: validationAudit.record)) }
            validationAudit.check(t, "cancelled validation")

            var interrupted = false
            let retryAudit = DescriptorAudit()
            let retried = try DeskPackageCapture.read(root: root, hooks: .init(at: retryAudit.record, read: { fd, buffer, count in
                if !interrupted { interrupted = true; errno = EINTR; return -1 }
                return Darwin.read(fd, buffer, count)
            }))
            t.check(interrupted)
            t.equal(try retried.source.read("large.asset", limit: 131_074), Data(repeating: 0xB3, count: 131_073))
            retryAudit.check(t, "EINTR retry")

            let readAudit = DescriptorAudit()
            rejects(t, .unreadable(EIO)) {
                _ = try DeskPackageCapture.read(root: root, hooks: .init(at: readAudit.record, read: { _, _, _ in errno = EIO; return -1 }))
            }
            readAudit.check(t, "read EIO")
            let shortAudit = DescriptorAudit()
            var shortReads = 0
            var verifiedAfterShortRead = false
            rejects(t, .changed) {
                _ = try DeskPackageCapture.read(root: root, hooks: .init(at: { checkpoint in
                    shortAudit.record(checkpoint)
                    if case .willVerifyManifest = checkpoint { verifiedAfterShortRead = true }
                }, read: { fd, buffer, count in
                    shortReads += 1
                    if shortReads == 1 { return Darwin.read(fd, buffer, min(count, 3)) }
                    return 0
                }))
            }
            t.equal(shortReads, 2, "a real partial first read followed by injected EOF must not return a partial file")
            t.check(!verifiedAfterShortRead, "the short read fails before final manifest verification")
            shortAudit.check(t, "premature EOF")
            let directoryAudit = DescriptorAudit()
            rejects(t, .unreadable(EIO)) {
                _ = try DeskPackageCapture.read(root: root, hooks: .init(at: directoryAudit.record, nextEntry: { _ in errno = EIO; return nil }))
            }
            directoryAudit.check(t, "readdir EIO is not clean EOF")
        }
    }

    private static func nameTests(_ t: AppTestRunner) {
        t.suite("App: Desk package capture: actual UTF8 names and the production alias validator preserve collision boundaries") {
            try DeskPackageCapture.validateNames(["Art", "Assets", ".ignored", "__MACOSX"], in: "")
            rejects(t, .ambiguous) { try DeskPackageCapture.validateNames(["Art", "art"], in: "") }
            rejects(t, .ambiguous) { try DeskPackageCapture.validateNames(["caf\u{00E9}", "cafe\u{0301}"], in: "assets") }
            try DeskPackageCapture.validateNames([".cache", ".CACHE", "__MACOSX"], in: "")

            for name in ["Art\\a.png", "C:", "~asset"] {
                let root = t.temporaryDirectory("desk-package-capture-unsafe-name")
                do {
                    let fd = Darwin.open(root.path + "/" + name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                    guard fd >= 0 else { throw FixtureFailure.setup }
                    defer { Darwin.close(fd) }
                    var byte: UInt8 = 1
                    guard withUnsafePointer(to: &byte, { Darwin.write(fd, $0, 1) }) == 1 else { throw FixtureFailure.setup }
                }
                t.equal(try rawNames(root).map { Array($0.utf8) }, [Array(name.utf8)], "the source really has this single POSIX basename")
                let audit = DescriptorAudit()
                var payloadReads = 0
                rejects(t, .invalidName(name)) {
                    _ = try DeskPackageCapture.read(root: root, hooks: .init(at: { checkpoint in
                        audit.record(checkpoint)
                        if case .willReadFile = checkpoint { payloadReads += 1 }
                    }))
                }
                t.equal(payloadReads, 0, "a spelling that cannot round-trip as a package path is rejected before payload reading")
                audit.check(t, "unsafe spelling " + name)
            }
            let colonRoot = t.temporaryDirectory("desk-package-capture-safe-colon")
            try write(Data([1]), "notes:keep.bin", in: colonRoot)
            let colonCapture = try DeskPackageCapture.read(root: colonRoot)
            t.equal(colonCapture.files.map { Array($0.path.utf8) }, [Array("notes:keep.bin".utf8)], "ordinary colon names remain literal package paths")
            t.equal(try colonCapture.source.read("notes:keep.bin", limit: 2), Data([1]))

            for names in [["Case.bin", "case.bin"], ["caf\u{00E9}.bin", "cafe\u{0301}.bin"]] {
                let root = t.temporaryDirectory("desk-package-capture-alias")
                for name in names { try write(Data([1]), name, in: root) }
                let actual = try rawNames(root)
                let distinctBytes = Set(actual.map { Array($0.utf8) })
                let actualPair = names.allSatisfy { wanted in actual.contains { DeskPackagePath.sameBytes($0, wanted) } }
                if actualPair && distinctBytes.count == 2 {
                    rejects(t, .ambiguous) { _ = try DeskPackageCapture.read(root: root) }
                } else {
                    t.equal(distinctBytes.count, 1, "this volume stores aliases as one actual name; no two-file collision is fabricated")
                    let capture = try DeskPackageCapture.read(root: root)
                    t.equal(capture.files.map { Array($0.path.utf8) }, actual.map { Array($0.utf8) })
                    t.equal(capture.totalBytes, 1)
                }
            }
        }
    }
}
