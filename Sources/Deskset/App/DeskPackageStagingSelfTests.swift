import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import DeskLanguage
import DesksetCore

/// Complete package installation into private scratch, with explicit file-worker/Main handoffs and no windows.
enum DeskPackageStagingSelfTests {
    private enum FixtureFailure: Error { case setup, timeout, wrongThread }

    private final class Worker {
        let queue = DispatchQueue(label: "desk.package.staging.tests")
        var staged: DeskWidgetInstallation.PackageStaged?

        func run<T>(_ operation: @escaping (Worker) throws -> T) throws -> T {
            let result = Guarded<Result<T, Error>?>(nil)
            queue.async {
                let answer = Result {
                    guard !Thread.isMainThread else { throw FixtureFailure.wrongThread }
                    return try operation(self)
                }
                result.access { $0 = answer }
            }
            guard AppSelfTest.spin(timeout: 15, until: { result.current != nil }), let answer = result.current else {
                throw FixtureFailure.timeout
            }
            return try answer.get()
        }

        func finish(_ decision: DeskWidgetInstallation.PackageDecision = .rejected) throws {
            try run { worker in
                defer { worker.staged = nil }
                try worker.staged?.finish(decision)
            }
        }
    }

    private struct Fixture {
        let root: URL
        let capture: DeskPackageCapture
        let snapshot: DeskSnapshot
        let worker: Worker
        let files: [(String, Data)]
    }

    private static let a = "\u{FEFF}info { name: \"Shared title\" }\r\nwidget { Column { Text(\"Greeting\").style(card); Image(\"Pictures/used.png\").size(8, 6) } }\r\n"
    private static let b = "info { name: \"Shared title\" }\nwidget { Text(\"Greeting\").style(card) }\n"
    private static let package = "package { name: \"Shared\" }\nstyle card { .font(18).padding(3) }\ntranslations { \"zh-Hans\" { \"Greeting\": \"问候\"; \"Shared title\": \"共享标题\" } }\n"

    private static func write(_ bytes: Data, _ path: String, in root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
    }

    private static func png() throws -> Data {
        let bytes = Data(repeating: 0xFF, count: 8 * 6 * 4)
        guard let provider = CGDataProvider(data: bytes as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw FixtureFailure.setup }
        let result = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw FixtureFailure.setup
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw FixtureFailure.setup }
        return result as Data
    }

    private static func fixture(_ t: AppTestRunner, second: String = b,
                                extra: [(String, Data)] = []) throws -> Fixture {
        let root = t.temporaryDirectory("desk-package-staging-source"), worker = Worker()
        let files = [("A.desk", Data(a.utf8)), ("B.desk", Data(second.utf8)), ("package.desk", Data(package.utf8)),
                     ("Pictures/used.png", try png()), ("Pictures/unused.png", Data([0, 255, 3])),
                     ("Fonts/unused.ttf", Data([0, 1, 0, 0, 19])), ("opaque.bin", Data([0, 255, 128, 1])),
                     ("nested/Other.desk", Data("retained bytes, not a root widget".utf8))] + extra
        for (path, bytes) in files { try write(bytes, path, in: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty/Deeper"), withIntermediateDirectories: true)
        try write(Data([99]), ".ignored/private.bin", in: root)
        let capture = try worker.run { _ in try DeskPackageCapture.read(root: root) }
        let snapshot = try worker.run { _ in
            let loaded = try PackageLoader.load(capture.source)
            return DeskLanguageService(package: loaded, openFile: DeskFileID("A.desk")).snapshot
        }
        t.atSuiteEnd { try? worker.finish() }
        return Fixture(root: root, capture: capture, snapshot: snapshot, worker: worker, files: files)
    }

    private static func admit(_ f: Fixture) throws -> DeskWidgetInstallation.PackageAdmission {
        try f.worker.run { _ in try DeskWidgetInstallation.admitPackage(f.snapshot, capture: f.capture) }
    }

    private static func plan(_ admitted: DeskWidgetInstallation.PackageAdmission) -> DeskWidgetInstallation.PackagePlan {
        .init(requestID: UUID(), packageID: UUID(), selected: DeskFileID("B.desk"), members: admitted.members.map {
            .init(file: $0.file, sourceID: UUID(), instanceID: UUID())
        })
    }

    private static func prepare(_ f: Fixture, admitted: DeskWidgetInstallation.PackageAdmission,
                                plan: DeskWidgetInstallation.PackagePlan, root: URL) throws -> URL {
        try f.worker.run { worker in
            worker.staged = try DeskWidgetInstallation.preparePackage(admitted, plan: plan, root: root)
            return worker.staged!.directory
        }
    }

    private static func publish(_ f: Fixture) throws -> DeskWidgetInstallation.PackagePublication {
        try f.worker.run { try $0.staged!.publish() }
    }

    private static func rejects(_ t: AppTestRunner, _ expected: DeskWidgetInstallation.Failure? = nil,
                                line: UInt = #line, _ operation: () throws -> Void) {
        do { try operation(); t.check(false, "operation unexpectedly succeeded", line: line) }
        catch {
            t.check(true, line: line)
            if let expected { t.equal(error as? DeskWidgetInstallation.Failure, expected, line: line) }
        }
    }

    private static func entries(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(by: DeskPackagePath.precedes)
    }

    private static func encoded(_ state: AppStateData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    static func run(_ t: AppTestRunner) {
        completeTests(t)
        admissionTests(t)
        tamperTests(t)
        raceTests(t)
        cancellationTests(t)
        registrationTests(t)
        foreignTests(t)
    }

    private static func completeTests(_ t: AppTestRunner) {
        t.suite("App: Desk package staging: complete original bytes and one shared checked tree install all inactive members") {
            let f = try fixture(t), admitted = try admit(f), plan = plan(admitted)
            t.equal(admitted.members.map { $0.file.path }, ["A.desk", "B.desk"])
            t.check(admitted.checked.checkedPackage != nil)
            for member in admitted.members {
                let exact = Desk.compile(admitted.checked.files[member.file]!, catalog: admitted.checked.catalog,
                                         package: admitted.checked.checkedPackage)
                t.equal(exact.program, member.program)
                t.equal(member.program.displayName(language: "zh-Hans"), "共享标题")
            }
            guard let second = admitted.members.last, case .text(let text) = second.program.root.content else { throw FixtureFailure.setup }
            t.equal(text.fontSize, 18, "both widgets consume the actual shared constant style")
            var runtime = try ProgramRuntime(program: second.program, language: "zh-Hans")
            let environment = EnvironmentStamp(scale: 1, fontGeneration: 1,
                appearance: AppearanceStamp(value: .light, name: "package"), imageGeneration: 0)
            let scene = try runtime.project(environment: environment) { _, _, _ in SkinSize(width: 40, height: 20) }
            t.equal(scene.drawingItems.compactMap { item -> String? in
                if case .text(let draw) = item { return draw.text }; return nil
            }, ["问候"])
            let foreignTree = CheckedDeskPackage(package: admitted.checked.package)
            let mismatched = Desk.compile(admitted.checked.files[second.file]!, package: foreignTree.checkedPackage)
            t.check(mismatched.program == nil, "another parse of identical package text is not a compatible receipt")

            let root = t.temporaryDirectory("desk-package-staging-install"), widgets = root.appendingPathComponent("Widgets")
            let staged = try prepare(f, admitted: admitted, plan: plan, root: widgets)
            let stagedCapture = try f.worker.run { _ in try DeskPackageCapture.read(root: staged) }
            t.equal(stagedCapture.files.map { Array($0.path.utf8) }, f.capture.files.map { Array($0.path.utf8) })
            t.equal(stagedCapture.directories.map { Array($0.path.utf8) }, f.capture.directories.map { Array($0.path.utf8) })
            for file in f.capture.files {
                t.equal(stagedCapture.files.first { DeskPackagePath.sameBytes($0.path, file.path) }?.bytes, file.bytes, file.path)
            }
            let publication = try publish(f), state = AppState(fileURL: root.appendingPathComponent("state.json"))
            t.check(state.data.deskWidgets.isEmpty, "publishing a directory does not register a partial package")
            let installed = try DeskWidgetInstallation.registerPackage(publication, to: state, current: { true })
            try f.worker.finish(.registered)
            t.equal(installed.sources.count, 2); t.equal(installed.instances.count, 2)
            t.check(installed.instances.allSatisfy { !$0.active })
            t.equal(installed.selectedInstanceID, plan.members.first { $0.file == plan.selected }?.instanceID)
            t.check(installed.sources.allSatisfy { $0.packageID == plan.packageID && $0.directoryID == plan.packageID })
            let reloaded = AppState(fileURL: root.appendingPathComponent("state.json"))
            t.equal(reloaded.data.deskWidgets, state.data.deskWidgets)
            for (path, bytes) in f.files {
                t.equal(try Data(contentsOf: installed.directory.appendingPathComponent(path)), bytes, path)
                t.equal(try Data(contentsOf: f.root.appendingPathComponent(path)), bytes, "original source remains unchanged")
            }
            t.equal(try entries(widgets), [plan.packageID.uuidString.lowercased()])
            t.equal(try entries(installed.directory.appendingPathComponent("Empty/Deeper")), [])
        }
    }

    private static func admissionTests(_ t: AppTestRunner) {
        t.suite("App: Desk package staging: unsupported erroneous or changed siblings and invalid referenced images reject the whole package") {
            for source in ["widget { Text(\"B\").margin(3) }", "widget { Text( }", "options { color = Toggle(\"Bad\") }"] {
                let f = try fixture(t, second: source)
                rejects(t) { _ = try admit(f) }
            }
            let f = try fixture(t), admitted = try admit(f)
            let changed = try f.worker.run { _ in
                let service = DeskLanguageService(package: admitted.checked.package, openFile: DeskFileID("A.desk"))
                return service.replaceText("widget { Text(\"Unsaved\") }", version: 1)
            }
            rejects(t, .sourceChanged) {
                _ = try f.worker.run { _ in try DeskWidgetInstallation.admitPackage(changed, capture: f.capture) }
            }
            let bad = try fixture(t, second: "widget { Image(\"bad.png\") }", extra: [("bad.png", Data([1, 2, 3]))])
            let badAdmission = try admit(bad), badPlan = plan(badAdmission)
            let destination = t.temporaryDirectory("desk-package-staging-bad-picture")
            rejects(t) { _ = try prepare(bad, admitted: badAdmission, plan: badPlan, root: destination) }
            t.equal(try entries(destination), [], "a bad image used only by a sibling publishes no directory")
            let incomplete = DeskWidgetInstallation.PackagePlan(requestID: UUID(), packageID: UUID(), selected: DeskFileID("A.desk"),
                                                                members: Array(plan(admitted).members.prefix(1)))
            rejects(t, .invalidSource) { _ = try prepare(f, admitted: admitted, plan: incomplete, root: destination) }
        }
    }

    private static func tamperTests(_ t: AppTestRunner) {
        t.suite("App: Desk package staging: every original file and empty directory belongs to the final bounded verification") {
            for mutation in ["same-size", "empty-directory", "extra-hidden", "file-link", "growth", "source-change"] {
                let f = try fixture(t), admitted = try admit(f), plan = plan(admitted)
                let widgets = t.temporaryDirectory("desk-package-staging-tamper"), staged = try prepare(f, admitted: admitted, plan: plan, root: widgets)
                switch mutation {
                case "same-size": try write(Data([9, 8, 7, 6]), "opaque.bin", in: staged)
                case "empty-directory": try FileManager.default.removeItem(at: staged.appendingPathComponent("Empty/Deeper"))
                case "extra-hidden": try write(Data([1]), ".extra", in: staged)
                case "file-link":
                    try FileManager.default.removeItem(at: staged.appendingPathComponent("opaque.bin"))
                    try FileManager.default.createSymbolicLink(at: staged.appendingPathComponent("opaque.bin"),
                                                              withDestinationURL: f.root.appendingPathComponent("opaque.bin"))
                case "growth": try write(Data(repeating: 1, count: 65_537), "opaque.bin", in: staged)
                default: try write(Data([4, 3, 2, 1]), "opaque.bin", in: f.root)
                }
                rejects(t, .sourceChanged) { _ = try publish(f) }
                try f.worker.finish()
                t.equal(try entries(widgets), [], mutation)
            }
        }
    }

    private static func raceTests(_ t: AppTestRunner) {
        t.suite("App: Desk package staging: M1 catches an already verified file changing and all bulk observations stay off Main") {
            let f = try fixture(t), admitted = try admit(f), plan = plan(admitted)
            let widgets = t.temporaryDirectory("desk-package-staging-M1"), staged = try prepare(f, admitted: admitted, plan: plan, root: widgets)
            var fired = false, offMain = true, hookError: Error?
            rejects(t, .sourceChanged) {
                _ = try f.worker.run { worker in
                    try worker.staged!.publish(observe: { point in
                        offMain = offMain && !Thread.isMainThread
                        guard case .didVerifyFile("A.desk") = point else { return }
                        fired = true
                        do { try write(Data(repeating: 32, count: Data(a.utf8).count), "A.desk", in: staged) }
                        catch { hookError = error }
                    })
                }
            }
            t.check(fired && offMain); t.check(hookError == nil)
            try f.worker.finish()
            t.equal(try entries(widgets), [])
        }
    }

    private static func cancellationTests(_ t: AppTestRunner) {
        t.suite("App: Desk package staging: cancellation during copy verification and before rename cleans only the worker lease") {
            for phase in ["copy", "verify", "rename"] {
                let f = try fixture(t), admitted = try admit(f), plan = plan(admitted)
                let widgets = t.temporaryDirectory("desk-package-staging-cancel"), cancelled = Guarded(false)
                var fired = false
                rejects(t, .disposed) {
                    _ = try f.worker.run { worker in
                        worker.staged = try DeskWidgetInstallation.preparePackage(admitted, plan: plan, root: widgets,
                            isCancelled: { cancelled.current }, observe: { point in
                                if phase == "copy", case .wroteFile = point { fired = true; cancelled.access { $0 = true } }
                            })
                        return try worker.staged!.publish(isCancelled: { cancelled.current }, observe: { point in
                            switch (phase, point) {
                            case ("verify", .willVerifyFiles), ("rename", .willRename): fired = true; cancelled.access { $0 = true }
                            default: break
                            }
                        })
                    }
                }
                t.check(fired && cancelled.current, phase)
                try f.worker.finish()
                t.equal(try entries(widgets), [], phase)
            }
        }
    }

    private static func registrationTests(_ t: AppTestRunner) {
        t.suite("App: Desk package staging: one Main batch save rejects stale and failed writes while saved state permanently revokes rollback") {
            for outcome in ["stale", "save-failure", "success"] {
                let f = try fixture(t), admitted = try admit(f), plan = plan(admitted)
                let root = t.temporaryDirectory("desk-package-staging-state"), widgets = root.appendingPathComponent("Widgets")
                _ = try prepare(f, admitted: admitted, plan: plan, root: widgets)
                let publication = try publish(f), blocker = root.appendingPathComponent("blocker")
                try Data([42]).write(to: blocker)
                let url = outcome == "save-failure" ? blocker.appendingPathComponent("state.json") : root.appendingPathComponent("state.json")
                let state = AppState(fileURL: url), before = state.data
                if outcome == "success" {
                    rejects(t, .disposed) { try f.worker.run { try $0.staged!.finish(.registered) } }
                    _ = try DeskWidgetInstallation.registerPackage(publication, to: state, current: { true })
                    let saved = try Data(contentsOf: url)
                    rejects(t, .disposed) { _ = try DeskWidgetInstallation.registerPackage(publication, to: state, current: { true }) }
                    try f.worker.finish(.rejected)
                    t.equal(try Data(contentsOf: url), saved)
                    t.check(FileManager.default.fileExists(atPath: publication.directory.path), "a late rejected ACK cannot delete saved state's directory")
                    t.equal(state.data.deskWidgets.sources.count, 2)
                } else {
                    rejects(t) { _ = try DeskWidgetInstallation.registerPackage(publication, to: state, current: { outcome != "stale" }) }
                    t.equal(try encoded(state.data), try encoded(before))
                    try f.worker.finish()
                    t.equal(try entries(widgets), [], outcome)
                    t.equal(try Data(contentsOf: blocker), Data([42]))
                }
            }
        }
    }

    private static func foreignTests(_ t: AppTestRunner) {
        t.suite("App: Desk package staging: exclusive rename and named publication identity preserve foreign directories") {
            for mutation in ["collision", "replace-publication", "replace-root"] {
                let f = try fixture(t), admitted = try admit(f), plan = plan(admitted)
                let root = t.temporaryDirectory("desk-package-staging-foreign"), widgets = root.appendingPathComponent("Widgets")
                _ = try prepare(f, admitted: admitted, plan: plan, root: widgets)
                let final = widgets.appendingPathComponent(plan.packageID.uuidString.lowercased())
                let held = root.appendingPathComponent("Held"), marker = Data("foreign directory survives".utf8)
                if mutation == "replace-publication" {
                    let publication = try publish(f)
                    try FileManager.default.moveItem(at: final, to: held)
                    try write(marker, "sentinel", in: final)
                    let state = AppState(fileURL: root.appendingPathComponent("state.json"))
                    rejects(t, .sourceChanged) { _ = try DeskWidgetInstallation.registerPackage(publication, to: state, current: { true }) }
                    t.check(state.data.deskWidgets.isEmpty)
                    try f.worker.finish()
                    t.equal(try entries(held), [])
                    t.equal(try Data(contentsOf: final.appendingPathComponent("sentinel")), marker)
                } else if mutation == "replace-root" {
                    try FileManager.default.moveItem(at: widgets, to: held)
                    try write(marker, "sentinel", in: widgets)
                    rejects(t, .sourceChanged) { _ = try publish(f) }
                    try f.worker.finish()
                    t.equal(try entries(held), [])
                    t.equal(try Data(contentsOf: widgets.appendingPathComponent("sentinel")), marker)
                } else {
                    try write(marker, "sentinel", in: final)
                    rejects(t, .collision) { _ = try publish(f) }
                    try f.worker.finish()
                    t.equal(try entries(widgets), [plan.packageID.uuidString.lowercased()])
                    t.equal(try Data(contentsOf: final.appendingPathComponent("sentinel")), marker)
                }
            }
        }
    }
}
