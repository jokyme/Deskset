import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin
import DeskLanguage
import DesksetCore

/// Installs only into private scratch. Real editor/service results, original encoded picture bytes and persisted
/// App state qualify this files-only slice; no desktop widget, host, permission or user installation is created.
enum DeskWidgetInstallationSelfTests {
    private enum Failure: Error { case fixture }
    private static let sourceID = UUID(uuidString: "ADA061F6-14F6-4CA2-A3C5-EC6888921254")!
    private static let instanceID = UUID(uuidString: "7B38FD07-0ADB-464C-9E22-84153317742D")!
    private static let text = "\u{FEFF}info { name: \"安装😀\" }\r\nwidget { Text(\"甲😀\").font(20) }\r\n"

    private struct Fixture {
        let root: URL
        let file: URL
        let app: AppController
        let controller: CodeFileWindowController
        var checking: DeskCodeDocumentChecking { controller.deskChecking! }
    }

    private static func fixture(_ t: AppTestRunner, _ text: String = DeskWidgetInstallationSelfTests.text,
                                images: [String: Data] = [:]) throws -> Fixture {
        let root = t.temporaryDirectory("desk-install-editor"), file = root.appendingPathComponent("Widget.desk")
        try Data(text.utf8).write(to: file)
        for (path, bytes) in images {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: root.appendingPathComponent("Skins"),
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false)
        let controller = try CodeFileWindowController(file: file, app: app,
                                                       deskCheckQueue: DispatchQueue(label: "desk.install.test.check"))
        controller.codeView.idleCommitDelay = 600
        controller.codeView.typedTextDelay = 600
        t.atSuiteEnd {
            controller.deskChecking?.close()
            controller.codeView.onCommit = { _, _ in false }
            controller.codeView.onDiskConflict = { _ in .decideLater }
            controller.codeView.discardUncommittedChanges()
            controller.window?.close()
            _ = app.stopAllForTermination()
            app.endEngineThread()
        }
        return Fixture(root: root, file: file, app: app, controller: controller)
    }

    private static func settled(_ f: Fixture) -> Bool {
        AppSelfTest.spin(timeout: 10) {
            let checking = f.checking, snapshot = checking.snapshot
            guard snapshot.isChecked, checking.isCurrent(snapshot) else { return false }
            if case .pending = checking.imageResources(for: snapshot) { return false }
            return true
        }
    }

    private static func admission(_ f: Fixture) throws -> DeskWidgetInstallation.Admission {
        try DeskWidgetInstallation.admit(f.checking.snapshot, file: f.file, current: f.checking.isCurrent)
    }

    private struct CheckedSource {
        let file: URL
        let service: DeskLanguageService
        func current(_ candidate: DeskSnapshot) -> Bool { candidate === service.snapshot }
        func admit() throws -> DeskWidgetInstallation.Admission {
            try DeskWidgetInstallation.admit(service.snapshot, file: file, current: current)
        }
    }

    /// A real public checker under smaller catalog limits qualifies budgets without allocating a 100 MiB fixture.
    private static func checked(_ t: AppTestRunner, _ text: String = DeskWidgetInstallationSelfTests.text,
                                catalog: DeskCatalog = .current) throws -> CheckedSource {
        let file = t.temporaryDirectory("desk-install-check").appendingPathComponent("Widget.desk")
        let bytes = Data(text.utf8)
        try bytes.write(to: file)
        guard case .text(let decoded, let id) = Desk.load(bytes, fileName: file.lastPathComponent) else { throw Failure.fixture }
        let service = DeskLanguageService(openFile: id, files: [id: decoded], options: DeskServiceOptions(catalog: catalog))
        return CheckedSource(file: file, service: service)
    }

    private static func rejects(_ t: AppTestRunner, _ expected: DeskWidgetInstallation.Failure? = nil,
                                _ operation: () throws -> Void, line: UInt = #line) {
        do { try operation(); t.check(false, "the operation unexpectedly succeeded", line: line) }
        catch {
            t.check(true, line: line)
            if let expected { t.equal(error as? DeskWidgetInstallation.Failure, expected, line: line) }
        }
    }

    private static func entries(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    static func run(_ t: AppTestRunner) {
        documentTests(t)
        resourceTests(t)
        versionTests(t)
        stagingTests(t)
        transactionTests(t)
        stateTests(t)
    }

    private static func documentTests(_ t: AppTestRunner) {
        t.suite("Desk: widget installation: real editor snapshot installs exact source without activation") {
            let f = try fixture(t)
            t.check(settled(f))
            let admitted = try admission(f), raw = Data(text.utf8)
            t.equal(admitted.document.bytes, raw)
            t.equal(admitted.program.name, "安装😀")
            let root = t.temporaryDirectory("desk-install-success"), stateURL = root.appendingPathComponent("state.json")
            let widgets = root.appendingPathComponent("Widgets"), state = AppState(fileURL: stateURL)
            let staged = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID, instanceID: instanceID, root: widgets)
            t.equal(try Data(contentsOf: staged.directory.appendingPathComponent("Widget.desk")), raw)
            let installed = try staged.commit(to: state, current: f.checking.isCurrent)
            t.equal(try Data(contentsOf: installed.directory.appendingPathComponent("Widget.desk")), raw,
                    "BOM, CRLF and surrogate-pair text are copied without rewriting the original")
            t.equal(try Data(contentsOf: f.file), raw)
            t.equal(installed.program, admitted.program, "the staged bytes were rechecked and compiled by the same shared compiler")
            let reloaded = AppState(fileURL: stateURL), key = sourceID.uuidString.lowercased()
            t.equal(reloaded.data.deskWidgets.sources[key]?.entry, key + "/Widget.desk")
            t.equal(reloaded.data.deskWidgets.instances[instanceID.uuidString.lowercased()]?.sourceID, sourceID)
            t.equal(reloaded.data.deskWidgets.instances[instanceID.uuidString.lowercased()]?.active, false)
            t.check(reloaded.activeConfigs.isEmpty && f.app.sortedControllers.isEmpty)
            t.equal(SkinLibrary.scan(widgets), [], "the legacy INI scanner does not install or activate Desk sources")
            t.equal(try entries(widgets), [key])
            rejects(t, .disposed) { _ = try staged.commit(to: state, current: f.checking.isCurrent) }
            t.check(FileManager.default.fileExists(atPath: installed.directory.path), "disposing an already committed lease preserves its installed files")
        }
    }

    private static func resourceTests(_ t: AppTestRunner) {
        t.suite("Desk: widget installation: frozen referenced images retain original bytes and relative spelling") {
            let png = try imageData()
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.fixture }
            t.equal(decoded.width, 8); t.equal(decoded.height, 6)
            let text = "widget { Column { Image(\".photos/甲😀.png\").size(48, 40); Image(\".PHOTOS/甲😀.PNG\").size(24, 20) } }"
            let f = try fixture(t, text, images: [".photos/甲😀.png": png, "unlisted.png": png])
            t.check(settled(f)); t.check(!f.checking.snapshot.diagnostics.contains { $0.severity == .error })
            let admitted = try admission(f)
            t.equal(admitted.imageSources, [".PHOTOS/甲😀.PNG", ".photos/甲😀.png"], "the compiler's documented byte-order demands")
            let root = t.temporaryDirectory("desk-install-images"), widgets = root.appendingPathComponent("Widgets")
            let state = AppState(fileURL: root.appendingPathComponent("state.json"))
            let staged = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID, instanceID: instanceID, root: widgets)
            t.equal(try entries(staged.directory), [".photos", "Widget.desk"])
            t.equal(try entries(staged.directory.appendingPathComponent(".photos")), ["甲😀.png"], "case aliases count as one actual file")
            let installed = try staged.commit(to: state, current: f.checking.isCurrent)
            t.equal(try Data(contentsOf: installed.directory.appendingPathComponent(".photos/甲😀.png")), png)
            t.equal(try Data(contentsOf: f.root.appendingPathComponent(".photos/甲😀.png")), png)
            t.check(!FileManager.default.fileExists(atPath: installed.directory.appendingPathComponent("unlisted.png").path))

            var small = DeskCatalog.current
            small.limits.maximumPackageBytes = admitted.document.bytes.count + png.count
            small.limits.maximumPackageFiles = 2
            let service = DeskLanguageService(package: DeskPackage(files: [DeskPackageFile(path: ".photos/甲😀.png", kind: .image,
                                                                                          size: png.count)],
                                                                  texts: [admitted.snapshot.file: text], isSingleFile: true),
                                              openFile: admitted.snapshot.file, options: DeskServiceOptions(catalog: small))
            let limited = try DeskWidgetInstallation.admit(service.snapshot, file: f.file, current: { $0 === service.snapshot })
            let atLimit = try DeskWidgetInstallation.prepare(limited, sourceID: sourceID, instanceID: instanceID,
                                                             root: root.appendingPathComponent("AtLimit"))
            atLimit.discard()
            t.equal(try entries(root.appendingPathComponent("AtLimit")), [])
            small.limits.maximumPackageFiles = 1
            service.setOptions(DeskServiceOptions(catalog: small))
            let tooFew = try DeskWidgetInstallation.admit(service.snapshot, file: f.file, current: { $0 === service.snapshot })
            rejects(t) { _ = try DeskWidgetInstallation.prepare(tooFew, sourceID: sourceID, instanceID: instanceID,
                                                               root: root.appendingPathComponent("TooFew")) }
            small.limits.maximumPackageFiles = 2
            small.limits.maximumPackageBytes -= 1
            service.setOptions(DeskServiceOptions(catalog: small))
            let tooSmall = try DeskWidgetInstallation.admit(service.snapshot, file: f.file, current: { $0 === service.snapshot })
            rejects(t) { _ = try DeskWidgetInstallation.prepare(tooSmall, sourceID: sourceID, instanceID: instanceID,
                                                                 root: root.appendingPathComponent("TooSmall")) }
            t.check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("TooFew").path))
            t.check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("TooSmall").path))
        }
    }

    private static func versionTests(_ t: AppTestRunner) {
        t.suite("Desk: widget installation: current revision disk bytes and resource generation are required") {
            let f = try fixture(t)
            t.check(settled(f))
            let old = f.checking.snapshot, before = Data(text.utf8)
            f.checking.recheck()
            t.check(settled(f)); t.check(!f.checking.isCurrent(old), "even a same-text recheck replaces the service generation")
            rejects(t, .staleSnapshot) { _ = try DeskWidgetInstallation.admit(old, file: f.file, current: f.checking.isCurrent) }
            let admitted = try admission(f), root = t.temporaryDirectory("desk-install-current")
            let widgets = root.appendingPathComponent("Widgets"), state = AppState(fileURL: root.appendingPathComponent("state.json"))
            let staged = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID, instanceID: instanceID, root: widgets)
            let changed = text.replacingOccurrences(of: "甲😀", with: "乙😀")
            let editor = f.controller.codeView, range = NSRange(location: 0, length: editor.text.utf16.count)
            editor.textView.setSelectedRange(range); editor.textView.insertText(changed, replacementRange: range)
            t.check(settled(f)); t.equal(try Data(contentsOf: f.file), before)
            rejects(t, .sourceChanged) { _ = try staged.commit(to: state, current: f.checking.isCurrent) }
            rejects(t, .sourceChanged) { _ = try admission(f) }
            editor.onCommit = { _, _ in false }
            t.check(!editor.commitNow(explicit: true), "a real refused save cannot install its dirty buffer")
            rejects(t, .sourceChanged) { _ = try admission(f) }
            t.equal(try entries(widgets), [])
            t.check(state.data.deskWidgets.isEmpty && f.app.sortedControllers.isEmpty)

            let disk = try checked(t)
            let admittedDisk = try disk.admit()
            try Data(changed.utf8).write(to: disk.file)
            rejects(t, .sourceChanged) { _ = try DeskWidgetInstallation.prepare(admittedDisk, sourceID: sourceID,
                                                                              instanceID: instanceID, root: root.appendingPathComponent("Changed")) }
            t.check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Changed").path))
            let image = try fixture(t, "widget { Image(\"asset.png\").size(48, 40) }", images: ["asset.png": try imageData()])
            t.check(settled(image))
            let imageStage = try DeskWidgetInstallation.prepare(admission(image), sourceID: sourceID, instanceID: instanceID,
                                                               root: root.appendingPathComponent("Images"))
            try Data([0, 1, 2]).write(to: image.root.appendingPathComponent("asset.png"))
            rejects(t, .sourceChanged) { _ = try imageStage.commit(to: state, current: image.checking.isCurrent) }
            t.equal(try entries(root.appendingPathComponent("Images")), [])
            f.checking.close()
            rejects(t, .staleSnapshot) { _ = try admission(f) }
        }
    }

    private static func stagingTests(_ t: AppTestRunner) {
        t.suite("Desk: widget installation: named directory identity and bounded staged bytes reject replacement") {
            let source = try checked(t), admitted = try source.admit()
            let root = t.temporaryDirectory("desk-install-replacement"), state = AppState(fileURL: root.appendingPathComponent("state.json"))
            let widgets = root.appendingPathComponent("Widgets")
            let staged = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID, instanceID: instanceID, root: widgets)
            let originalName = staged.directory, moved = widgets.appendingPathComponent("moved-owned")
            try FileManager.default.moveItem(at: originalName, to: moved)
            try FileManager.default.createDirectory(at: originalName, withIntermediateDirectories: false)
            let marker = Data("foreign directory must survive".utf8)
            try marker.write(to: originalName.appendingPathComponent("sentinel"))
            rejects(t, .sourceChanged) { _ = try staged.commit(to: state, current: source.current) }
            t.equal(try Data(contentsOf: originalName.appendingPathComponent("sentinel")), marker)
            t.equal(try entries(moved), [], "cleanup uses the held FD, never the substituted directory")
            t.check(!FileManager.default.fileExists(atPath: widgets.appendingPathComponent(sourceID.uuidString.lowercased()).path))
            t.check(state.data.deskWidgets.isEmpty)

            for mutation in ["giant", "append", "same-size", "extra", "link"] {
                let destination = root.appendingPathComponent(mutation)
                let lease = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID, instanceID: instanceID, root: destination)
                let file = lease.directory.appendingPathComponent("Widget.desk")
                switch mutation {
                case "giant":
                    let fd = open(file.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                    guard fd >= 0 else { throw Failure.fixture }
                    defer { Darwin.close(fd) }
                    guard ftruncate(fd, off_t(DeskCatalog.current.limits.maximumPackageBytes + 1)) == 0 else { throw Failure.fixture }
                case "append": try (admitted.document.bytes + Data([32])).write(to: file)
                case "same-size": try Data(repeating: 32, count: admitted.document.bytes.count).write(to: file)
                case "extra": try Data([9]).write(to: lease.directory.appendingPathComponent("unlisted.png"))
                default:
                    try FileManager.default.removeItem(at: file)
                    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source.file)
                }
                rejects(t, .sourceChanged) { _ = try lease.commit(to: state, current: source.current) }
                t.equal(try entries(destination), [], "\(mutation) leaves no owned staged or final directory")
                t.equal(try Data(contentsOf: source.file), admitted.document.bytes)
                t.check(state.data.deskWidgets.isEmpty)
            }
            let movedRoot = root.appendingPathComponent("MovedRoot"), replacement = root.appendingPathComponent("Replacement")
            let lease = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID, instanceID: instanceID, root: movedRoot)
            let heldRoot = root.appendingPathComponent("HeldRoot")
            try FileManager.default.moveItem(at: movedRoot, to: heldRoot)
            try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: movedRoot, withDestinationURL: replacement)
            try marker.write(to: replacement.appendingPathComponent("sentinel"))
            rejects(t, .sourceChanged) { _ = try lease.commit(to: state, current: source.current) }
            t.equal(try entries(heldRoot), [])
            t.equal(try Data(contentsOf: replacement.appendingPathComponent("sentinel")), marker)
        }
    }

    private static func transactionTests(_ t: AppTestRunner) {
        t.suite("Desk: widget installation: collisions unsupported input and failed state save leave no registration") {
            let source = try checked(t), admitted = try source.admit()
            let root = t.temporaryDirectory("desk-install-transaction"), widgets = root.appendingPathComponent("Widgets")
            let stage = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID, instanceID: instanceID, root: widgets)
            let final = widgets.appendingPathComponent(sourceID.uuidString.lowercased())
            try FileManager.default.createDirectory(at: final, withIntermediateDirectories: false)
            let marker = Data("do not overwrite".utf8)
            try marker.write(to: final.appendingPathComponent("sentinel"))
            let state = AppState(fileURL: root.appendingPathComponent("state.json"))
            rejects(t, .collision) { _ = try stage.commit(to: state, current: source.current) }
            t.equal(try Data(contentsOf: final.appendingPathComponent("sentinel")), marker)
            t.equal(try entries(widgets), [sourceID.uuidString.lowercased()])
            rejects(t, .collision) { _ = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID, instanceID: instanceID, root: widgets) }
            let droppedRoot = root.appendingPathComponent("Dropped")
            var dropped: DeskWidgetInstallation.Staged? = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID,
                                                                                              instanceID: instanceID, root: droppedRoot)
            t.check(dropped != nil)
            dropped = nil
            t.equal(try entries(droppedRoot), [], "an uncommitted lease cleans up on its last release")
            let failedRoot = root.appendingPathComponent("Failed")
            let failed = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID, instanceID: instanceID, root: failedRoot)
            let blocker = root.appendingPathComponent("not-a-directory")
            try marker.write(to: blocker)
            let unwritableState = AppState(fileURL: blocker.appendingPathComponent("state.json"))
            rejects(t) { _ = try failed.commit(to: unwritableState, current: source.current) }
            t.equal(try Data(contentsOf: blocker), marker)
            t.check(unwritableState.data.deskWidgets.isEmpty)
            t.equal(try entries(failedRoot), [], "failed persistence rolls back the renamed owned directory")

            for text in ["widget { Text(\"A\").margin(3) }", "widget { Text(\"A\").onWake { } }"] {
                let unsupported = try checked(t, text)
                rejects(t, .unsupported) { _ = try unsupported.admit() }
            }
            let link = source.file.deletingLastPathComponent().appendingPathComponent("Link.desk")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.file)
            let linkID = DeskFileID(path: "Link.desk")
            let service = DeskLanguageService(openFile: linkID, files: [linkID: text])
            rejects(t) { _ = try DeskWidgetInstallation.admit(service.snapshot, file: link, current: { $0 === service.snapshot }) }
            var small = DeskCatalog.current; small.limits.maximumPackageBytes = admitted.document.bytes.count - 1
            let limited = try checked(t, catalog: small)
            rejects(t, .resourceLimit) { _ = try DeskWidgetInstallation.prepare(limited.admit(), sourceID: sourceID,
                                                                              instanceID: instanceID, root: root.appendingPathComponent("TooLarge")) }
            t.check(state.data.deskWidgets.isEmpty && !FileManager.default.fileExists(atPath: root.appendingPathComponent("TooLarge").path))
            for invalid in [Data([0xFF, 0xFE, 0x00, 0x61]), Data([0xC0, 0xAF])] {
                if case .rejected = Desk.load(invalid, fileName: "Invalid.desk") { t.check(true) }
                else { t.check(false, "the actual strict loader accepted invalid source bytes") }
            }
        }
    }

    private static func stateTests(_ t: AppTestRunner) {
        t.suite("Desk: widget installation: distinct inactive identities preserve legacy and future state") {
            let root = t.temporaryDirectory("desk-install-state"), url = root.appendingPathComponent("state.json")
            let old = #"{"skins":{"Legacy\\Clock":{"file":"Clock.ini","active":true,"x":13,"y":29,"futureSkin":[1,"keep"]}},"defaultSkinsInstalled":2,"futureRoot":{"keep":true}}"#
            try Data(old.utf8).write(to: url)
            let state = AppState(fileURL: url)
            t.check(state.data.deskWidgets.isEmpty)
            let legacy = state.data.skins
            let before = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.data)) as! NSDictionary
            t.check(before["deskWidgets"] == nil, "older state gains no empty Desk namespace")
            // Equal UUIDs are safe across the source and instance namespaces, unlike a reused dictionary key.
            let key = sourceID.uuidString.lowercased()
            var source = DeskWidgetSourceState(id: sourceID, entry: key + "/Widget.desk")
            source.unknownKeys = ["futureSource": .string("keep")]
            var instance = DeskWidgetInstanceState(id: sourceID, sourceID: sourceID)
            instance.unknownKeys = ["futureInstance": .array([.number(3), .bool(true)])]
            try state.registerDeskInstallation(source: source, instance: instance)
            let reloaded = AppState(fileURL: url)
            t.equal(reloaded.data.skins, legacy)
            t.equal(reloaded.activeConfigs.map(\.config), ["Legacy\\Clock"])
            t.equal(reloaded.data.deskWidgets.sources[key], source)
            t.equal(reloaded.data.deskWidgets.instances[key], instance)
            let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! NSDictionary
            let legacyAfter = after.mutableCopy() as! NSMutableDictionary
            legacyAfter.removeObject(forKey: "deskWidgets")
            t.check(before.isEqual(legacyAfter), "all normalized legacy settings and unknown top-level keys roundtrip unchanged")
            let rawBefore = try Data(contentsOf: url)
            rejects(t) { try reloaded.registerDeskInstallation(source: source, instance: instance) }
            t.equal(try Data(contentsOf: url), rawBefore)
            t.equal(reloaded.data.deskWidgets.sources.count, 1)
            var active = DeskWidgetInstanceState(id: instanceID, sourceID: instanceID); active.active = true
            let different = DeskWidgetSourceState(id: instanceID, entry: instanceID.uuidString.lowercased() + "/Widget.desk")
            rejects(t) { try reloaded.registerDeskInstallation(source: different, instance: active) }
            let mismatch = DeskWidgetInstanceState(id: instanceID, sourceID: sourceID)
            rejects(t) { try reloaded.registerDeskInstallation(source: different, instance: mismatch) }
            let matching = DeskWidgetInstanceState(id: instanceID, sourceID: instanceID)
            rejects(t) { try reloaded.registerDeskInstallation(source: DeskWidgetSourceState(id: instanceID, entry: "../Widget.desk"), instance: matching) }
            t.equal(try Data(contentsOf: url), rawBefore)

            let future = """
            {"skins":{},"deskWidgets":{"futureNamespace":{"keep":4},"sources":{"\(key)":{"id":"\(sourceID)","entry":"\(key)/Widget.desk","futureSource":5}},"instances":{"\(key)":{"id":"\(sourceID)","sourceID":"\(sourceID)","futureInstance":"yes"}}}}
            """
            try Data(future.utf8).write(to: url)
            let forward = AppState(fileURL: url)
            t.equal(forward.data.deskWidgets.instances[key]?.active, false, "missing active never implies a restored live host")
            forward.saveNow()
            let saved = AppState(fileURL: url)
            t.equal(saved.data.deskWidgets.unknownKeys, ["futureNamespace": .object(["keep": .number(4)])])
            t.equal(saved.data.deskWidgets.sources[key]?.unknownKeys, ["futureSource": .number(5)])
            t.equal(saved.data.deskWidgets.instances[key]?.unknownKeys, ["futureInstance": .string("yes")])
        }
    }

    private static func imageData() throws -> Data {
        var bytes: [UInt8] = []
        for y in 0..<6 { for x in 0..<8 { bytes += x < 4 ? [24, 168, 72, 255] : (y < 3 ? [80, 24, 112, 128] : [216, 88, 16, 255]) } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.fixture }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw Failure.fixture }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw Failure.fixture }
        return output as Data
    }
}
