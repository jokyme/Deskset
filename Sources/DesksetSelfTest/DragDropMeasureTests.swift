import Foundation
@testable import DesksetCore

func runDragDropMeasureTests(_ t: TestRunner) {
    t.suite("DragDrop: delete waits for confirmation and cancellation preserves files") {
        let host = DragDropConfirmationHost()
        let f = try dragDropFixture(t, host: host, options: """
        OnDropAction=[!SetVariable Dropped "$FileNr$|$Name$|$Type$|$Directory$|$File$|$MouseX$|$MouseY$"]
        """)
        defer { f.skin.close() }
        t.check(f.measure.handleDrop(files: f.files, x: 12, y: 34))
        t.equal(host.requests.count, 1)
        t.equal(host.requests.first?.paths, [f.files[0]])
        t.check(f.effects.records.isEmpty, "trash is not requested before an answer")
        t.equal(f.measure.stringValue, f.files[0])
        let folder = (f.files[0] as NSString).deletingLastPathComponent
        t.equal(f.skin.variable("Dropped"), "1|first note|txt|\(folder)|\(f.files[0])|12|34")
        host.requests.first?.answer(false)
        host.requests.first?.answer(true)
        t.check(f.effects.records.isEmpty, "a cancelled answer cannot later be changed to approval")
        t.equal(try String(contentsOfFile: f.files[0], encoding: .utf8), "first")
    }

    t.suite("DragDrop: confirmed batch deletes each selected path exactly once") {
        let host = DragDropConfirmationHost()
        let f = try dragDropFixture(t, host: host, options: """
        ProcessAllFiles=1
        OnDropAction=[!Log "Drop:$FileNr$:$Name$"]
        """)
        defer { f.skin.close() }
        t.check(f.measure.handleDrop(files: f.files, x: 0, y: 0))
        t.equal(host.requests.count, 1)
        t.equal(host.requests.first?.paths, f.files)
        t.check(f.effects.records.isEmpty)
        t.equal(host.base.logs, ["Notice: Drop:1:first note", "Notice: Drop:2:second"])
        t.equal(f.measure.stringValue, f.files[1])
        host.requests.first?.answer(true)
        t.equal(f.effects.records, f.files.map { .removeFile(path: $0) })
        host.requests.first?.answer(true)
        t.equal(f.effects.records.count, 2)
        t.equal(try String(contentsOfFile: f.files[0], encoding: .utf8), "first",
                "the test effects never execute a real trash operation")
        t.equal(try String(contentsOfFile: f.files[1], encoding: .utf8), "second")
    }

    t.suite("DragDrop: Silent suppresses confirmation and recording never opens a dialog") {
        for isLive in [true, false] {
            for silent in [0, 1] {
                let host = DragDropConfirmationHost()
                let f = try dragDropFixture(t, host: host, isLive: isLive,
                                            options: "Silent=\(silent)\nProcessAllFiles=1")
                defer { f.skin.close() }
                f.measure.handleDrop(files: f.files, x: 0, y: 0)
                if isLive && silent == 0 {
                    t.equal(host.requests.count, 1)
                    t.check(f.effects.records.isEmpty)
                    host.requests.first?.answer(false)
                } else {
                    t.equal(host.requests.count, 0)
                    t.equal(f.effects.records, f.files.map { .removeFile(path: $0) })
                }
            }
        }
        let host = DragDropConfirmationHost()
        let f = try dragDropFixture(t, host: host)
        defer { f.skin.close() }
        let recording = RecordingSideEffects(directory: t.temporaryDirectory("drag-drop-recording"))
        f.skin.sideEffects = recording
        f.measure.handleDrop(files: f.files, x: 0, y: 0)
        t.equal(host.requests.count, 0)
        t.equal(recording.records, [.removeFile(path: f.files[0])])
        t.equal(try String(contentsOfFile: f.files[0], encoding: .utf8), "first")
    }

    t.suite("DragDrop: a host without confirmation and a missing host decline deletion") {
        let host = FakeHost()
        let f = try dragDropFixture(t, host: host)
        defer { f.skin.close() }
        t.check(f.measure.handleDrop(files: f.files, x: 0, y: 0))
        t.check(f.effects.records.isEmpty, "SkinHost's default answer is decline")
        f.skin.host = nil
        t.check(f.measure.handleDrop(files: f.files, x: 0, y: 0))
        t.check(f.effects.records.isEmpty, "a missing host cannot grant consent")
    }

    t.suite("DragDrop: closed disabled and paused measures ignore late approval") {
        for state in ["closed", "disabled", "paused"] {
            let host = DragDropConfirmationHost()
            let f = try dragDropFixture(t, host: host)
            defer { f.skin.close() }
            f.measure.handleDrop(files: f.files, x: 0, y: 0)
            t.equal(host.requests.count, 1)
            switch state {
            case "closed": f.skin.close()
            case "disabled": f.skin.execute("[!DisableMeasure DD]", from: nil)
            default: f.skin.execute("[!PauseMeasure DD]", from: nil)
            }
            host.requests.first?.answer(true)
            t.check(f.effects.records.isEmpty, "late approval must not act on a \(state) measure")
        }
    }

    t.suite("DragDrop: pending approval keeps its original file list and action") {
        let host = DragDropConfirmationHost()
        let f = try dragDropFixture(t, host: host)
        defer { f.skin.close() }
        f.measure.handleDrop(files: [f.files[0]], x: 0, y: 0)
        f.skin.execute("[!SetOption DD Action Path][!UpdateMeasure DD]", from: nil)
        f.measure.handleDrop(files: [f.files[1]], x: 0, y: 0)
        t.equal(host.requests.count, 1)
        t.equal(f.measure.stringValue, f.files[1])
        host.requests.first?.answer(true)
        t.equal(f.effects.records, [.removeFile(path: f.files[0])])
    }

    t.suite("DragDrop: child inherits Silent and ProcessAllFiles from its parent") {
        let host = DragDropConfirmationHost()
        let f = try dragDropFixture(t, host: host, ini: """
        [Parent]
        Measure=DragDrop
        Action=Delete
        Silent=1
        ProcessAllFiles=1
        [DD]
        Measure=DragDrop
        Parent=Parent
        DynamicVariables=1
        OnDropAction=[!Log "Child:$FileNr$:$Name$"]
        """)
        defer { f.skin.close() }
        f.measure.handleDrop(files: f.files, x: 0, y: 0)
        t.equal(host.requests.count, 0)
        t.equal(f.effects.records, f.files.map { .removeFile(path: $0) })
        t.equal(f.skin.measure(named: "Parent")?.stringValue, f.files[1])
        t.equal(host.base.logs, ["Notice: Child:1:first note", "Notice: Child:2:second"])
        f.effects.clearRecords()
        f.skin.execute("[!SetOption Parent Silent 0][!UpdateMeasure Parent][!UpdateMeasure DD]", from: nil)
        f.measure.handleDrop(files: f.files, x: 0, y: 0)
        t.equal(host.requests.count, 1)
        t.equal(host.requests.first?.paths, f.files)
        f.skin.execute("[!DisableMeasure Parent]", from: nil)
        host.requests.first?.answer(true)
        t.check(f.effects.records.isEmpty, "a disabled parent also invalidates pending deletion")
    }

    t.suite("DragDrop: rejected and inactive drops never request confirmation") {
        let host = DragDropConfirmationHost()
        let f = try dragDropFixture(t, host: host, options: "Bounds=10,20,30,40")
        defer { f.skin.close() }
        t.check(!f.measure.handleDrop(files: [], x: 15, y: 25))
        t.check(!f.measure.handleDrop(files: f.files, x: 0, y: 0))
        f.skin.execute("[!PauseMeasure DD]", from: nil)
        t.check(!f.measure.handleDrop(files: f.files, x: 15, y: 25))
        t.equal(host.requests.count, 0)
        t.check(f.effects.records.isEmpty)
    }
}

private struct DragDropFixture {
    let skin: Skin
    let measure: DragDropMeasure
    let effects: DragDropEffectProbe
    let files: [String]
}

private func dragDropFixture(_ t: TestRunner, host: SkinHost?, isLive: Bool = true,
                             options: String = "", ini: String? = nil) throws -> DragDropFixture {
    let root = t.temporaryDirectory("drag-drop-measure")
    let skinURL = root.appendingPathComponent("Skin.ini")
    try (ini ?? "[DD]\nMeasure=DragDrop\nAction=Delete\n\(options)\n")
        .write(to: skinURL, atomically: true, encoding: .utf8)
    let first = root.appendingPathComponent("first note.txt")
    let second = root.appendingPathComponent("second.md")
    try "first".write(to: first, atomically: true, encoding: .utf8)
    try "second".write(to: second, atomically: true, encoding: .utf8)
    let effects = DragDropEffectProbe(isLive: isLive, directory: root.appendingPathComponent("Recording"))
    let skin = Skin(config: "DragDrop", fileURL: skinURL, skinsDirectory: root,
                    system: FakeSystem(), host: host)
    skin.sideEffects = effects
    try skin.load()
    skin.update()
    guard let measure = skin.measure(named: "DD") as? DragDropMeasure else {
        throw NSError(domain: "DragDropMeasureTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "DragDrop measure was not loaded"])
    }
    return DragDropFixture(skin: skin, measure: measure, effects: effects, files: [first.path, second.path])
}

private final class DragDropConfirmationHost: SkinHost {
    struct Request {
        let paths: [String]
        let answer: (Bool) -> Void
    }
    let base = FakeHost()
    var requests: [Request] = []

    func skin(_ skin: Skin, confirmFileTrash paths: [String], answered: @escaping (Bool) -> Void) {
        requests.append(Request(paths: paths, answer: answered))
    }
    func skinNeedsDisplay(_ skin: Skin) { base.skinNeedsDisplay(skin) }
    func skin(_ skin: Skin, handle bang: Bang) -> Bool { base.skin(skin, handle: bang) }
    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {
        base.skin(skin, forward: bang, toConfig: config)
    }
    func skin(_ skin: Skin, execute target: String, arguments: [String]) {
        base.skin(skin, execute: target, arguments: arguments)
    }
    func skin(_ skin: Skin, log message: String, level: SkinLogLevel) { base.skin(skin, log: message, level: level) }
    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
        base.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
    }
    func imageSize(atPath path: String) -> (width: Double, height: Double)? { base.imageSize(atPath: path) }
    func environment(for skin: Skin) -> SkinEnvironment { base.environment(for: skin) }
}

/// Reports either live or recording mode, but always records instead of invoking a filesystem closure.
private final class DragDropEffectProbe: SideEffects {
    let isLive: Bool
    private let recording: RecordingSideEffects
    var records: [SideEffect] { recording.records }
    var fileSandbox: SkinFileSandbox? { recording.fileSandbox }

    init(isLive: Bool, directory: URL) {
        self.isLive = isLive
        recording = RecordingSideEffects(directory: directory)
    }
    func clearRecords() { recording.clearRecords() }
    func perform(_ effect: SideEffect, live: () -> Void) { recording.record(effect) }
    func startShellCommand(_ command: String, directory: String, maxOutput: Int, locale: Locale) throws -> SkinProcess {
        try recording.startShellCommand(command, directory: directory, maxOutput: maxOutput, locale: locale)
    }
    func launch(_ executable: String, _ arguments: [String], completion: ((Int32) -> Void)?) {
        recording.launch(executable, arguments, completion: completion)
    }
    func destination(forWriting url: URL) -> URL { recording.destination(forWriting: url) }
    func temporaryDestination(for url: URL) -> URL { recording.temporaryDestination(for: url) }
    func writeFile(_ data: Data, to url: URL, makingFolder: Bool) throws {
        try recording.writeFile(data, to: url, makingFolder: makingFolder)
    }
    func removeTemporaryFile(atPath path: String) { recording.removeTemporaryFile(atPath: path) }
    func writeKeyValue(_ value: String, key: String, section: String, fileURL: URL) throws {
        try recording.writeKeyValue(value, key: key, section: section, fileURL: fileURL)
    }
}
