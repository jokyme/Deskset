import AppKit
import Darwin
import DeskLanguage
import DesksetCore

/// Real editor buffers and scratch files; package work is held on controlled queues. No application window,
/// installer, desktop activation or user file participates.
enum DeskPackageEditorSelfTests {
    private enum Failure: Error { case fixture(String) }
    private static let fileWorker = DispatchQueue(label: "desk.package.editor.tests.files")
    private static let member = DeskFileID("Widget.desk")
    private static let source = "info { name: \"Member\" }\nwidget { Text(\"Member\").style(shared) }\n"
    private static let shared = "package { name: \"Shared\" }\nstyle shared { .color(\"#FF0000\") }\n"
    private static let sibling = "info { name: \"Sibling\" }\nwidget { Text(\"Sibling\").style(shared) }\n"

    private struct Fixture {
        let input: DeskCodePackageInput
        let editor: CodeEditorView
        let io: DeskPackageMemberIO
        let checker: DeskCodeDocumentChecking
        let queue: DispatchQueue
    }

    static func run(_ t: AppTestRunner) {
        captureAndCache(t)
        refreshAndOverlay(t)
        saveAndConflict(t)
        pendingAndIdentity(t)
        replacedRoot(t)
        memberReadSafety(t)
        memberWriteSafety(t)
    }

    private static func input(_ t: AppTestRunner, source: String = DeskPackageEditorSelfTests.source,
                              extra: [(String, Data)] = []) throws -> DeskCodePackageInput {
        let root = t.temporaryDirectory("desk-package-editor")
        let files = [(member.path, Data(source.utf8)), ("package.desk", Data(shared.utf8)),
                     ("Sibling.desk", Data(sibling.utf8)), ("unused.txt", Data("unused".utf8))] + extra
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        return try fileWorker.sync {
            try DeskCodePackageInput(capture: DeskPackageCapture.read(root: root), member: member)
        }
    }

    private static func fixture(_ t: AppTestRunner, input: DeskCodePackageInput,
                                queue: DispatchQueue = DispatchQueue(label: "desk.package.editor.tests.check")) throws -> Fixture {
        let editor = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        editor.idleCommitDelay = 600
        editor.typedTextDelay = 600
        editor.requiresUnchangedSourceForAutomaticCommit = true
        editor.decodeDocument = DeskCodeDocumentChecking.document(from:file:)
        editor.readData = { file in
            guard DeskPackagePath.sameBytes(file.standardizedFileURL.path, input.file.path) else {
                throw Failure.fixture("opening a different member")
            }
            return input.memberBytes
        }
        try editor.open(files: [input.file], current: input.file)
        let io = try DeskPackageMemberIO(capture: input.capture, member: input.member)
        editor.readData = io.read
        editor.onCommit = { [weak editor] file, text in
            guard let data = editor?.document(for: file)?.data(for: text) else { return false }
            do { try io.write(data, to: file); return true } catch { return false }
        }
        editor.onDiskConflict = { _ in .decideLater }
        let checker = DeskCodeDocumentChecking(file: input.file, editor: editor, checkingOn: queue, package: input)
        t.atSuiteEnd {
            checker.close()
            editor.onCommit = { _, _ in false }
            editor.discardUncommittedChanges()
        }
        return Fixture(input: input, editor: editor, io: io, checker: checker, queue: queue)
    }

    private static func ready(_ f: Fixture) -> Bool {
        AppSelfTest.spin(timeout: 10) { f.checker.snapshot.isChecked && f.checker.isCurrent(f.checker.snapshot) }
    }

    private static func refresh(_ f: Fixture, reload: Bool = false) throws -> DeskCodePackageSnapshot {
        var result: Result<DeskCodePackageSnapshot, Error>?
        f.checker.refreshPackage(reloadMember: reload) { result = $0 }
        guard AppSelfTest.spin(timeout: 10, until: { result != nil }), let result else {
            throw Failure.fixture("package refresh did not complete")
        }
        return try result.get()
    }

    private static func type(_ text: String, in editor: CodeEditorView) {
        CodeEditorSelfTests.type(editor, text, at: 0)
    }

    private static func images(_ f: Fixture) throws -> [String: ProgramImageResource] {
        guard case .ready(let images) = f.checker.imageResources(for: f.checker.snapshot) else {
            throw Failure.fixture("package images not ready")
        }
        return images
    }

    private static func colors(_ snapshot: DeskSnapshot) throws -> [RGBA] {
        let compilation = Desk.compile(snapshot.checked, catalog: snapshot.options.catalog, package: snapshot.package)
        guard let program = compilation.program else {
            throw Failure.fixture("compilation: \(compilation.diagnostics) \(compilation.issues)")
        }
        var runtime = try ProgramRuntime(program: program)
        let input = DeskConditionalTestSupport.input()
        let scene = try runtime.project(environment: input.environment, colorInput: input.colors) { _, _, _ in
            SkinSize(width: 48, height: 16)
        }
        return scene.elements.flatMap(\.items).compactMap {
            if case .text(let text) = $0 { return text.style.color }
            return nil
        }
    }

    private static func png() throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32),
              let pixels = rep.bitmapData else { throw Failure.fixture("PNG bitmap") }
        for pixel in 0..<6 {
            pixels[pixel * 4] = UInt8(20 + pixel * 10)
            pixels[pixel * 4 + 1] = 80
            pixels[pixel * 4 + 2] = 160
            pixels[pixel * 4 + 3] = 255
        }
        guard let bytes = rep.representation(using: .png, properties: [:]) else { throw Failure.fixture("PNG encoding") }
        return bytes
    }

    private static func captureAndCache(_ t: AppTestRunner) {
        t.suite("App: Desk package editor: capture bytes, complete siblings and cached images share one input") {
            let bytes = try png()
            let source = "\u{FEFF}info { name: \"Member\" }\r\nwidget { Column {\r\n"
                + "Text(\"Member\").style(shared)\r\nImage(\"picture.png\")\r\n} }\r\n"
            let captured = try input(t, source: source, extra: [("picture.png", bytes)])
            let changedOnDisk = source + "// newer disk member\r\n"
            try Data(changedOnDisk.utf8).write(to: captured.file)
            let f = try fixture(t, input: captured)
            t.equal(f.editor.text, source)
            t.equal(f.editor.document(for: captured.file)?.data(for: f.editor.text), captured.memberBytes)
            var initialFailure: Error?
            f.checker.onPackageFailure = { initialFailure = $0 }
            t.check(AppSelfTest.spin(timeout: 10) { initialFailure != nil },
                    "a later disk read cannot silently turn the old capture into a mixed package")
            t.check(!f.checker.isCurrent(f.checker.snapshot))
            _ = try refresh(f, reload: true)
            t.equal(f.editor.text, changedOnDisk)
            t.check(ready(f), "the complete new capture qualified before publication")
            let snapshot = f.checker.snapshot
            t.equal(snapshot.folder[DeskFileID("Sibling.desk")], sibling)
            t.equal(snapshot.folder[DeskFileID("package.desk")], shared)
            let whole = snapshot.packageCheck()
            t.equal(whole.files[DeskFileID("package.desk")]?.tree.version, snapshot.package?.tree.version)
            guard let other = whole.files[DeskFileID("Sibling.desk")], let package = snapshot.package else {
                throw Failure.fixture("whole package checks")
            }
            t.check(Desk.compile(other, package: package).program != nil, "sibling receipts use the same shared tree")
            let image = try images(f)["picture.png"]
            guard let image else { throw Failure.fixture("private picture") }
            t.equal(image.naturalSize, SkinSize(width: 3, height: 2))
            t.equal(try Data(contentsOf: URL(fileURLWithPath: image.path)), bytes)
            var publications = 0
            f.checker.onSnapshot = { _ in publications += 1 }
            try FileManager.default.removeItem(at: captured.capture.root.appendingPathComponent("picture.png"))
            try Data("externally changed".utf8).write(to: captured.capture.root.appendingPathComponent("unused.txt"))
            for _ in 0..<8 {
                t.equal(try images(f)["picture.png"], image, "Main getter is a cached immutable result")
                t.check(f.checker.isCurrent(snapshot))
            }
            t.equal(publications, 0, "getter did not trigger disk qualification or restart preparation")
            t.equal(try Data(contentsOf: URL(fileURLWithPath: image.path)), bytes)
            var failure: Error?
            f.checker.onPackageFailure = { failure = $0 }
            do { _ = try refresh(f); t.check(false, "missing referenced image must reject refresh") }
            catch { t.check(failure != nil && !f.checker.isCurrent(snapshot)) }
            t.check(!FileManager.default.fileExists(atPath: image.path), "invalidated private copy was released")
            try bytes.write(to: captured.capture.root.appendingPathComponent("picture.png"))
            let recovered = try refresh(f)
            t.check(f.checker.isCurrent(recovered.snapshot))
            t.equal(try images(f)["picture.png"]?.naturalSize, SkinSize(width: 3, height: 2))
        }
    }

    private static func refreshAndOverlay(_ t: AppTestRunner) {
        t.suite("App: Desk package editor: refresh retains the latest buffer while replacing package and sibling receipts") {
            let captured = try input(t)
            let f = try fixture(t, input: captured)
            t.check(ready(f))
            t.equal(try colors(f.checker.snapshot), [DeskConditionalTestSupport.red])
            let old = f.checker.snapshot
            f.queue.suspend()
            var suspended = true
            defer { if suspended { f.queue.resume() } }
            type("// first edit\n", in: f.editor)
            let nextShared = shared.replacingOccurrences(of: "#FF0000", with: "#0000FF")
            let nextSibling = sibling.replacingOccurrences(of: "Sibling", with: "Changed")
            try Data(nextShared.utf8).write(to: captured.capture.root.appendingPathComponent("package.desk"))
            try Data(nextSibling.utf8).write(to: captured.capture.root.appendingPathComponent("Sibling.desk"))
            var result: Result<DeskCodePackageSnapshot, Error>?
            f.checker.refreshPackage { result = $0 }
            type("// latest edit\n", in: f.editor)
            let latest = f.editor.text, revision = f.editor.textRevision
            f.queue.resume(); suspended = false
            t.check(AppSelfTest.spin(timeout: 10) { result != nil })
            guard let result else { throw Failure.fixture("refresh callback") }
            let accepted = try result.get()
            t.equal(accepted.snapshot.version, revision)
            t.equal(accepted.snapshot.text, latest)
            t.equal(accepted.snapshot.folder[member], latest)
            t.equal(accepted.input.memberBytes, captured.memberBytes, "only the current member is an unsaved overlay")
            t.equal(accepted.snapshot.folder[DeskFileID("package.desk")], nextShared)
            t.equal(accepted.snapshot.folder[DeskFileID("Sibling.desk")], nextSibling)
            t.equal(try colors(accepted.snapshot), [DeskConditionalTestSupport.blue])
            t.check(!f.checker.publish(old))
            t.check(f.editor.isDirty && f.editor.textView.undoManager?.canUndo == true)
            t.equal(try Data(contentsOf: captured.file), captured.memberBytes)
            let whole = accepted.snapshot.packageCheck()
            t.equal(whole.files[DeskFileID("package.desk")]?.tree.version, accepted.snapshot.package?.tree.version)
            guard let other = whole.files[DeskFileID("Sibling.desk")] else { throw Failure.fixture("sibling") }
            t.check(Desk.compile(other, package: accepted.snapshot.package).program != nil)
            t.check(try images(f).isEmpty, "a package without images still completes full freshness")
            try Data("changed without any image demand".utf8).write(to: captured.capture.root.appendingPathComponent("unused.txt"))
            let noImages = try refresh(f)
            t.equal(noImages.input.capture.files.first(where: { $0.path == "unused.txt" })?.bytes,
                    Data("changed without any image demand".utf8))
            t.check(!f.checker.isCurrent(accepted.snapshot))
        }
    }

    private static func saveAndConflict(_ t: AppTestRunner) {
        t.suite("App: Desk package editor: dirty reload preserves conflict base, undo and synchronous real saves") {
            let original = "\u{FEFF}" + source.replacingOccurrences(of: "\n", with: "\r\n")
            let captured = try input(t, source: original)
            let f = try fixture(t, input: captured)
            t.check(ready(f))
            type("// typed\r\n", in: f.editor)
            let typed = f.editor.text
            let external = original.replacingOccurrences(of: "Text(\"Member\")", with: "Text(\"External\")")
            try Data(external.utf8).write(to: captured.file)
            _ = try refresh(f, reload: true)
            t.equal(f.editor.text, typed)
            t.check(f.editor.isDirty && f.editor.textView.undoManager?.canUndo == true)
            t.equal(f.editor.checkSourceUnchanged(for: captured.file), .changed)
            t.check(f.editor.fireIdleCommit(), "the pending automatic commit was attempted")
            t.check(f.editor.isDirty, "the source guard retains the dirty buffer")
            t.equal(try Data(contentsOf: captured.file), Data(external.utf8),
                    "automatic commit cannot overwrite the external file")
            t.check(!f.editor.commitNow(explicit: true), "decide later retains the same dirty buffer")
            t.equal(try Data(contentsOf: captured.file), Data(external.utf8))
            f.editor.onDiskConflict = { _ in .keepEdits }
            t.check(f.editor.commitNow(explicit: true), "existing synchronous hook wrote the complete document")
            t.equal(try Data(contentsOf: captured.file), Data(typed.utf8), "BOM and CRLF survive the bounded writer")
            t.check(!f.editor.hasUncommittedChanges)
            t.equal(f.editor.checkSourceUnchanged(for: captured.file), .unchanged)
            let saved = try refresh(f)
            t.equal(saved.input.memberBytes, Data(typed.utf8))
            t.equal(saved.snapshot.text, typed)
            type("// another edit\r\n", in: f.editor)
            try Data(external.utf8).write(to: captured.file)
            f.editor.onDiskConflict = { _ in .takeDisk }
            t.check(f.editor.commitNow(explicit: true))
            t.equal(f.editor.text, external)
            t.check(!f.editor.isDirty)
            t.equal(try Data(contentsOf: captured.file), Data(external.utf8))
            type("// retain on decode failure\r\n", in: f.editor)
            let retained = f.editor.text
            try Data([0xff, 0xfe, 0x41, 0x00]).write(to: captured.file)
            do { _ = try refresh(f, reload: true); t.check(false, "invalid bytes must not replace the buffer") }
            catch let error as DeskCodeDocumentChecking.ReadFailure { t.equal(error.diagnostic.id, .invalidEncoding) }
            t.equal(f.editor.text, retained)
            t.check(f.editor.isDirty && f.editor.textView.undoManager?.canUndo == true)
        }
    }

    private static func pendingAndIdentity(_ t: AppTestRunner) {
        t.suite("App: Desk package editor: superseded and closed requests finish once and contexts cannot share snapshots") {
            let captured = try input(t)
            let f = try fixture(t, input: captured), other = try fixture(t, input: captured)
            t.check(ready(f)); t.check(ready(other))
            t.equal(f.checker.snapshot.version, other.checker.snapshot.version)
            t.equal(f.checker.snapshot.generation, other.checker.snapshot.generation)
            t.equal(f.checker.snapshot.text, other.checker.snapshot.text)
            t.check(!f.checker.isCurrent(other.checker.snapshot))
            t.check(!other.checker.publish(f.checker.snapshot), "equal counters never authorize another context")
            f.queue.suspend()
            var suspended = true
            defer { if suspended { f.queue.resume() } }
            var first: [Result<DeskCodePackageSnapshot, Error>] = []
            var second: [Result<DeskCodePackageSnapshot, Error>] = []
            f.checker.refreshPackage { first.append($0) }
            f.checker.refreshPackage { second.append($0) }
            t.equal(first.count, 1); t.equal(second.count, 0)
            if case .failure(let error)? = first.first {
                t.equal(error as? DeskPackageCapture.Failure, .cancelled)
            } else { t.check(false, "superseded request must cancel") }
            f.queue.resume(); suspended = false
            t.check(AppSelfTest.spin(timeout: 10) { second.count == 1 })
            t.equal(first.count, 1)
            guard case .success(let accepted)? = second.first else { throw Failure.fixture("latest refresh") }
            t.check(f.checker.isCurrent(accepted.snapshot))
            var closed: [Result<DeskCodePackageSnapshot, Error>] = []
            var publications = 0
            f.checker.onSnapshot = { _ in publications += 1 }
            f.queue.suspend(); suspended = true
            f.checker.refreshPackage { closed.append($0) }
            f.checker.close(); f.checker.close()
            let count = publications
            t.equal(closed.count, 1)
            if case .failure(let error)? = closed.first {
                t.equal(error as? DeskPackageCapture.Failure, .cancelled)
            } else { t.check(false, "close must cancel") }
            f.queue.resume(); suspended = false
            var drained = false
            f.queue.async { DispatchQueue.main.async { drained = true } }
            t.check(AppSelfTest.spin(timeout: 10) { drained })
            t.equal(closed.count, 1); t.equal(publications, count)
            t.check(!f.checker.isCurrent(accepted.snapshot))
            t.check(other.checker.isCurrent(other.checker.snapshot), "closing one owner does not close another")
        }
    }

    private static func replacedRoot(_ t: AppTestRunner) {
        t.suite("App: Desk package editor: root replacement is rejected and restoring the explicit root can recover") {
            let captured = try input(t), root = captured.capture.root
            let f = try fixture(t, input: captured)
            t.check(ready(f))
            let moved = root.deletingLastPathComponent().appendingPathComponent("desk-original-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: moved) }
            try FileManager.default.moveItem(at: root, to: moved)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try captured.memberBytes.write(to: captured.file)
            try Data(shared.utf8).write(to: root.appendingPathComponent("package.desk"))
            do { _ = try refresh(f, reload: true); t.check(false, "same path with new root identity is not selected") }
            catch let error as DeskPackageCapture.Failure { t.equal(error, .changed("")) }
            t.equal(f.editor.text, source)
            t.equal(f.editor.checkSourceUnchanged(for: captured.file), .unavailable)
            t.check(!f.checker.isCurrent(f.checker.snapshot))
            try FileManager.default.removeItem(at: root)
            try FileManager.default.moveItem(at: moved, to: root)
            let recovered = try refresh(f, reload: true)
            t.check(f.checker.isCurrent(recovered.snapshot))
            t.equal(recovered.input.capture.rootIdentity.inode, captured.capture.rootIdentity.inode)
        }
    }

    private final class DescriptorAudit {
        var active = Set<Int32>()
        var errors: [String] = []
        func record(_ checkpoint: DeskPackageMemberIO.Checkpoint) {
            switch checkpoint {
            case .openedDescriptor(let fd):
                if !active.insert(fd).inserted { errors.append("duplicate descriptor \(fd)") }
            case .closedDescriptor(let fd):
                if active.remove(fd) == nil { errors.append("unexpected close \(fd)") }
                errno = 0
                if fcntl(fd, F_GETFD) != -1 || errno != EBADF { errors.append("descriptor \(fd) was not closed") }
            default: break
            }
        }
        func check(_ t: AppTestRunner) { t.equal(errors, []); t.check(active.isEmpty) }
    }

    private static func rejects(_ t: AppTestRunner, _ expected: DeskPackageMemberIO.Failure,
                                line: UInt = #line, _ body: () throws -> Void) {
        do { try body(); t.check(false, "member operation unexpectedly succeeded", line: line) }
        catch let failure as DeskPackageMemberIO.Failure { t.equal(failure, expected, line: line) }
        catch { t.check(false, "unexpected error \(error)", line: line) }
    }

    private static func memberReadSafety(_ t: AppTestRunner) {
        t.suite("App: Desk package editor: bounded member reads reject links, replacements and failed read receipts") {
            let captured = try input(t), audit = DescriptorAudit()
            var unreadable = false, shortRead = false, replaceWhileReading = false
            let hooks = DeskPackageMemberIO.Hooks(at: { checkpoint in
                audit.record(checkpoint)
                if case .willRead = checkpoint, replaceWhileReading {
                    replaceWhileReading = false
                    try? Data("replacement".utf8).write(to: captured.file, options: .atomic)
                }
            }, read: { fd, bytes, count in
                if unreadable { errno = EIO; return -1 }
                if shortRead { return 0 }
                return Darwin.read(fd, bytes, count)
            })
            let io = try DeskPackageMemberIO(capture: captured.capture, member: member, hooks: hooks)
            t.equal(try io.read(captured.file), captured.memberBytes)
            unreadable = true
            rejects(t, .unreadable(EIO)) { _ = try io.read(captured.file) }
            rejects(t, .changed) { try io.write(Data("must not write".utf8), to: captured.file) }
            unreadable = false; shortRead = true
            rejects(t, .changed) { _ = try io.read(captured.file) }
            shortRead = false; replaceWhileReading = true
            rejects(t, .changed) { _ = try io.read(captured.file) }
            t.equal(try Data(contentsOf: captured.file), Data("replacement".utf8))
            rejects(t, .invalidMember) { _ = try io.read(captured.capture.root.appendingPathComponent("Sibling.desk")) }
            let target = captured.capture.root.appendingPathComponent("outside.txt")
            try Data("target".utf8).write(to: target)
            try FileManager.default.removeItem(at: captured.file)
            try FileManager.default.createSymbolicLink(at: captured.file, withDestinationURL: target)
            rejects(t, .invalidMember) { _ = try io.read(captured.file) }
            rejects(t, .changed) { try io.write(Data("escaped".utf8), to: captured.file) }
            t.equal(try Data(contentsOf: target), Data("target".utf8))
            try FileManager.default.removeItem(at: captured.file)
            try Data(repeating: 65, count: captured.capture.limits.maximumFileBytes + 1).write(to: captured.file)
            rejects(t, .oversized) { _ = try io.read(captured.file) }
            audit.check(t)
        }
    }

    private static func memberWriteSafety(_ t: AppTestRunner) {
        t.suite("App: Desk package editor: member writes complete short writes and clean failures without touching replacements") {
            let captured = try input(t), audit = DescriptorAudit()
            var failWrite = false, replaceBeforePublish = false
            let replacement = Data("external replacement".utf8)
            let io = try DeskPackageMemberIO(capture: captured.capture, member: member, hooks: .init(at: { checkpoint in
                audit.record(checkpoint)
                if case .willReplace = checkpoint, replaceBeforePublish {
                    replaceBeforePublish = false
                    try? replacement.write(to: captured.file, options: .atomic)
                }
            }, write: { fd, bytes, count in
                if failWrite { errno = ENOSPC; return -1 }
                return Darwin.write(fd, bytes, min(count, 7))
            }))
            _ = try io.read(captured.file)
            let saved = Data(("\u{FEFF}" + source.replacingOccurrences(of: "\n", with: "\r\n")).utf8)
            try io.write(saved, to: captured.file)
            t.equal(try Data(contentsOf: captured.file), saved)
            rejects(t, .changed) { try io.write(Data("no read receipt".utf8), to: captured.file) }
            _ = try io.read(captured.file)
            failWrite = true
            rejects(t, .writeFailed(ENOSPC)) { try io.write(captured.memberBytes, to: captured.file) }
            failWrite = false
            t.equal(try Data(contentsOf: captured.file), saved)
            _ = try io.read(captured.file)
            replaceBeforePublish = true
            rejects(t, .changed) { try io.write(Data("unaccepted".utf8), to: captured.file) }
            t.equal(try Data(contentsOf: captured.file), replacement)
            let names = try FileManager.default.contentsOfDirectory(atPath: captured.capture.root.path)
            t.check(!names.contains { $0.hasPrefix(".deskset-editor-") }, "every owned temporary file was removed")
            _ = try io.read(captured.file)
            rejects(t, .oversized) {
                try io.write(Data(repeating: 0, count: captured.capture.limits.maximumFileBytes + 1), to: captured.file)
            }
            t.equal(try Data(contentsOf: captured.file), replacement)
            audit.check(t)
        }
    }
}
