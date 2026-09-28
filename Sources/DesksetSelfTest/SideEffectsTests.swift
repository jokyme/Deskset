import Darwin
import Foundation
@testable import DesksetCore

// The seam for a skin's side effects (the runtime design, "side-effect sandbox"): what a skin does outside itself is
// done for real (`LiveSideEffects`) or only recorded (`RecordingSideEffects`, with `RecordingSkinHost` for what it asks
// of its host), and the state a run leaves in the skin's variables can be read (`Skin.runtimeVariables`).

/// The repository's TestSkins folder.
private let testSkinsFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("TestSkins")

/// Spins the main run loop until `condition` holds (true) or `timeout` passes (false).
@discardableResult
private func spinUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

/// Every file under `folder` (relative path → bytes), symbolic links as their target's path.
private func snapshot(_ folder: URL) -> [String: Data] {
    var files: [String: Data] = [:]
    let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else {
        return files
    }
    for case let url as URL in walker {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            files[relative + "/"] = Data()
        } else {
            files[relative] = (try? Data(contentsOf: url)) ?? Data("<unreadable>".utf8)
        }
    }
    return files
}

func runSideEffectsSeamTests(_ t: TestRunner) {
    t.suite("Seams: side effects: live and recording implementations") { try liveAndRecording(t) }
    t.suite("Seams: side effects: a recording host keeps what the skin asks of its host") { try recordingHost(t) }
    t.suite("Seams: side effects: every exit of a skin is recorded, and the skin's folder and the Mac are left alone") { try everyExit(t) }
    t.suite("Seams: side effects: the Studio's policy brings a recording") { try studioPolicy(t) }
    t.suite("Seams: runtime variables") { try runtimeVariables(t) }
}

private func liveAndRecording(_ t: TestRunner) throws {
    // Live: the effect runs at once.
    var ran = false
    LiveSideEffects.shared.perform(.mediaKey("PlayPause")) { ran = true }
    t.check(ran, "live side effects run what they are given")
    t.check(LiveSideEffects.shared.isLive)
    t.check(LiveSideEffects.shared.fileSandbox == nil, "live scripts write the files themselves")
    let somewhere = URL(fileURLWithPath: "/tmp/somewhere.txt")
    t.equal(LiveSideEffects.shared.destination(forWriting: somewhere), somewhere)
    t.equal(LiveSideEffects.shared.temporaryDestination(for: somewhere), somewhere)

    // A recording: nothing runs, everything is kept, in order.
    let root = t.temporaryDirectory("side-effects-unit")
    let skins = root.appendingPathComponent("Skins")
    let recording = RecordingSideEffects(skinsDirectory: skins, directory: root.appendingPathComponent("Copy"))
    t.check(!recording.isLive)
    var told: [SideEffect] = []
    recording.onRecord = { told.append($0) }
    ran = false
    recording.perform(.audio(.changeVolume(10))) { ran = true }
    t.check(!ran, "a recording never runs the effect")
    var status: Int32?
    recording.launch("/usr/bin/open", ["-R", "/tmp"]) { status = $0 }
    t.equal(status, 0, "a helper program 'exits' at once")
    let process = try recording.startShellCommand("echo hi", directory: "/tmp", maxOutput: 4, locale: Locale(identifier: "en_US"))
    recording.programOutput = { _ in Data("never read: the process was made".utf8) }
    var exited = false
    process.onExit = { exited = true }
    process.resume()
    t.check(exited, "a recorded program exits as soon as it is resumed")
    t.equal(process.outputSnapshot(), Data(), "with the output it was given (none by default)")
    t.check(process.signal(SIGTERM))
    let expected: [SideEffect] = [
        .audio(.changeVolume(10)),
        .launch(executable: "/usr/bin/open", arguments: ["-R", "/tmp"], directory: nil),
        .launch(executable: "/bin/sh", arguments: ["-c", "echo hi"], directory: "/tmp"),
        .signal(SIGTERM, command: "echo hi"),
    ]
    t.equal(recording.records, expected)
    t.equal(told, expected, "and told, in the same order")
    recording.programOutput = { Data("out: \($0)".utf8) }
    let limited = try recording.startShellCommand("x", directory: "/tmp", maxOutput: 6, locale: .current)
    t.equal(String(decoding: limited.outputSnapshot(), as: UTF8.self), "out: x", "the given output, up to maxOutput")
    let clipped = try recording.startShellCommand("longer", directory: "/tmp", maxOutput: 4, locale: .current)
    t.equal(String(decoding: clipped.outputSnapshot(), as: UTF8.self), "out:")

    // Files: a write goes to the copy of the skin tree, keeping its place there; the file itself is left alone.
    let skinFolder = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: skinFolder, withIntermediateDirectories: true)
    let ini = skinFolder.appendingPathComponent("Skin.ini")
    try "[Variables]\nCount=0\n".write(to: ini, atomically: true, encoding: .utf8)
    recording.clearRecords()
    let target = skinFolder.appendingPathComponent("DownloadFile/logo.png")
    let destination = recording.destination(forWriting: target)
    t.check(destination.path.hasSuffix("/Skins/Root/Sub/DownloadFile/logo.png"), "in the tree: \(destination.path)")
    t.check(recording.files.contains(destination.path))
    try recording.writeFile(Data("LOGO".utf8), to: destination, makingFolder: true)
    t.equal(try? String(contentsOf: destination, encoding: .utf8), "LOGO")
    t.check(!FileManager.default.fileExists(atPath: target.path), "not the real file")
    // A path from elsewhere never reaches the Mac: it is sent to its copy first.
    let stray = skinFolder.appendingPathComponent("stray.txt")
    try recording.writeFile(Data("S".utf8), to: stray, makingFolder: false)
    t.check(!FileManager.default.fileExists(atPath: stray.path), "a stray path is written to the copy")
    t.equal(recording.files.copy(of: stray.path).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }, "S")
    // !WriteKeyValue writes the copy, which a reload reads (the recording is a source provider).
    try recording.writeKeyValue("5", key: "Count", section: "Variables", fileURL: ini)
    t.equal(try? String(contentsOf: ini, encoding: .utf8), "[Variables]\nCount=0\n", "the skin's file is left alone")
    t.equal(recording.sourceText(for: ini), "[Variables]\nCount=5\n", "the copy has the key")
    t.equal(recording.sourceText(for: skinFolder.appendingPathComponent("Other.ini")), nil, "other files: the disk")
    do {
        try recording.writeKeyValue("1", key: "A", section: "S", fileURL: skinFolder.appendingPathComponent("No.ini"))
        t.check(false, "a missing file is an error, as for the file itself")
    } catch let error as IniWriterError {
        t.equal(error, .fileNotFound(skinFolder.appendingPathComponent("No.ini").path))
    }
    t.equal(recording.records, [
        .writeFile(path: target.path),
        .writeFile(path: stray.path),
        .writeKeyValue(file: ini.path, section: "Variables", key: "Count", value: "5"),
    ])
    // A temporary file of the app's own: in the scratch folder, not recorded; only that folder is ever cleaned.
    let temporary = recording.temporaryDestination(for: URL(fileURLWithPath: NSTemporaryDirectory() + "x-page.html"))
    t.check(recording.files.contains(temporary.path), "in the scratch folder: \(temporary.path)")
    try recording.writeFile(Data("T".utf8), to: temporary, makingFolder: true)
    recording.removeTemporaryFile(atPath: temporary.path)
    t.check(!FileManager.default.fileExists(atPath: temporary.path))
    recording.removeTemporaryFile(atPath: ini.path)
    t.check(FileManager.default.fileExists(atPath: ini.path), "a path outside the recording is never removed")
    t.equal(recording.records.count, 3, "temporary files are not recorded")
    // A copy is made of a link's target, never of the link (writing through a copied link would reach the file).
    let real = skinFolder.appendingPathComponent("real.txt")
    try "REAL".write(to: real, atomically: true, encoding: .utf8)
    let link = skinFolder.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let linkCopy = recording.files.path(for: link.path, access: .update)
    let attributes = try FileManager.default.attributesOfItem(atPath: linkCopy)
    t.equal(attributes[.type] as? FileAttributeType, .typeRegular, "the copy is a file")
    try "CHANGED".write(toFile: linkCopy, atomically: false, encoding: .utf8)
    t.equal(try? String(contentsOf: real, encoding: .utf8), "REAL", "the link's target is left alone")
    // reset: a new instance starts from the real files.
    recording.reset()
    t.equal(recording.sourceText(for: ini), nil)
    t.equal(recording.records.count, 4, "the records stay")
    recording.clearRecords()
    t.equal(recording.records, [])
}

private func recordingHost(_ t: TestRunner) throws {
    let recording = RecordingSideEffects()
    let host = RecordingSkinHost(effects: recording)
    let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        Update=1000
        [Meter]
        Meter=String
        Text=x
        """)
    skin.host = host
    skin.execute("[\"https://example.com\" --flag][!Move 10 20][!SetVariable A 1 \"Other\\Config\"]", from: nil)
    t.equal(recording.records, [
        .open(target: "https://example.com", arguments: ["--flag"]),
        .hostBang("!Move 10 20"),
        .forwardBang("!SetVariable A 1", config: "Other\\Config"),
    ])
    t.check(host.textSize("abc\nd", style: TextStyle(), wrapWidth: nil, for: skin).width > 0, "text is measured")
    skin.log("hello", level: .notice)
    t.check(host.log.contains { $0.message.contains("hello") }, "the log is kept")
    skin.close()
}

private func everyExit(_ t: TestRunner) throws {
    let skins = t.temporaryDirectory("side-effects").appendingPathComponent("Skins")
    let folder = skins.appendingPathComponent("Engine/SideEffects")
    try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: testSkinsFolder.appendingPathComponent("Engine/SideEffects"), to: folder)
    let before = snapshot(skins)
    t.check(before["Engine/SideEffects/SideEffects.ini"] != nil, "the test skin was copied")

    // No helper program may start, and the Trash is a folder of the test's.
    let savedLauncher = PluginProcess.launcher
    var launched = 0
    PluginProcess.launcher = { _, _, _ in launched += 1 }
    defer { PluginProcess.launcher = savedLauncher }
    // FileView's icons: made by the app's renderer (here the test's), written through the skin's side effects.
    let savedRenderer = FileViewIcons.renderer
    FileViewIcons.renderer = { _, _, pathExtension in Data("icon-\(pathExtension)".utf8) }
    defer { FileViewIcons.renderer = savedRenderer }
    let trash = t.temporaryDirectory("side-effects-trash")
    let savedFolders = TrashMonitor.folders
    TrashMonitor.folders = { [trash.path] }
    defer { TrashMonitor.folders = savedFolders }

    let recording = RecordingSideEffects(skinsDirectory: skins, directory: t.temporaryDirectory("side-effects-copy"))
    recording.programOutput = { Data("output of \($0)\n".utf8) }
    let host = RecordingSkinHost(effects: recording, inner: FakeHost())
    let ini = folder.appendingPathComponent("SideEffects.ini")
    let skin = Skin(config: "Engine\\SideEffects", fileURL: ini, skinsDirectory: skins, system: FakeSystem(),
                    host: host)
    skin.sideEffects = recording
    t.check(skin.sideEffects === recording)
    try skin.load()
    skin.update()
    t.check(spinUntil { (skin.measure(named: "MeasureFolder") as? FileViewMeasure)?.isReading == false },
            "FileView read the folder")
    t.equal(recording.records, [], "nothing happens outside the skin until the click")

    let go = skin.meter(named: "MeterGo")!.frame
    t.check(skin.mouseEvent(.leftUp, x: go.x + 2, y: go.y + 2), "the click is handled")
    t.check(spinUntil { skin.measure(named: "MeasureRun")?.value == 1 }, "the recorded program finished")
    t.check(spinUntil {
        (skin.measure(named: "MeasureDownload") as? WebParserMeasure)?.isDownloading == false
            && (skin.measure(named: "MeasurePage") as? WebParserMeasure)?.isFetching == false
            && skin.measure(named: "MeasureOut")?.stringValue.isEmpty == false
    }, "WebParser finished")
    t.check(spinUntil {
        skin.measure(named: "MeasureIcon")?.stringValue.isEmpty == false
            && skin.measure(named: "MeasureIconPath")?.stringValue.isEmpty == false
    }, "the icons were written")

    let dir = folder.path
    let tmp = skin.variable("TmpName") ?? ""
    t.check(tmp.hasPrefix("/tmp/lua_") && tmp.count == 15, "os.tmpname's name: \(tmp)")
    let expected: [SideEffect] = [
        .launch(executable: "/bin/sh", arguments: ["-c", "echo hello"], directory: dir),
        .signal(SIGKILL, command: "echo hello"),
        .launch(executable: "/usr/bin/open", arguments: ["-R", dir + "/"], directory: nil),
        .launch(executable: "/usr/bin/osascript",
                arguments: ["-e", "tell application \"Finder\"", "-e", "activate",
                            "-e", "open information window of (POSIX file \"\(dir)/\" as alias)", "-e", "end tell"],
                directory: nil),
        // FileView's icon files: icon1.ico in the skin's folder (no IconPath) and the IconPath.
        .writeFile(path: dir + "/icon1.ico"),
        .writeFile(path: dir + "/Icons/Folder.png"),
        .launch(executable: "/usr/bin/open", arguments: [TrashMonitor.homeTrash], directory: nil),
        .writeFile(path: dir + "/DownloadFile/copy.html"),
        .writeFile(path: dir + "/WebParserDump.txt"),
        .writeKeyValue(file: ini.path, section: "Variables", key: "Count", value: "5"),
        .writeKeyValue(file: dir + "/Data.inc", section: "Variables", key: "Theme", value: "dark"),
        .writeFile(path: dir + "/new.txt"),
        .renameFile(from: dir + "/new.txt", to: dir + "/moved.txt"),
        .removeFile(path: dir + "/moved.txt"),
        // os.tmpname made the file, the script wrote it and removed it: all in the copy.
        .writeFile(path: tmp),
        .removeFile(path: tmp),
        .open(target: dir + "/", arguments: []),
        .hostBang("!Move 10 20"),
        .forwardBang("!SetVariable Shared 1", config: "Engine\\Other"),
        // After the program's exit came back: its OutputFile.
        .writeFile(path: dir + "/out.txt"),
    ]
    t.equal(recording.records, expected, "exactly these, in this order")
    for (index, effect) in recording.records.enumerated() where index >= expected.count || effect != expected[index] {
        t.check(false, "record \(index): \(effect)")
    }
    t.equal(launched, 0, "no helper program started")
    t.check(!FileManager.default.fileExists(atPath: tmp), "no temporary file on the Mac")
    t.equal(snapshot(skins), before, "the skin's folder is as it was")

    // The skin went on as it would, on the copies.
    t.equal(skin.measure(named: "MeasureRun")?.stringValue, "output of echo hello\n", "the program's given output")
    t.equal(skin.measure(named: "MeasureOut")?.stringValue, "output of echo hello\n",
            "WebParser reads the OutputFile the program wrote, from the copy")
    t.equal(skin.imageFilePath("DownloadFile\\copy.html", imagePath: ""),
            recording.files.copy(of: dir + "/DownloadFile/copy.html"), "an image path finds the copy of a download")
    t.equal(skin.imageFilePath("page.html", imagePath: ""), dir + "/page.html", "and a file it did not write itself")
    let out = recording.files.copy(of: dir + "/out.txt")
    t.equal(out.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }, "output of echo hello\n",
            "OutputFile is in the copy")
    let downloaded = skin.measure(named: "MeasureDownload")?.stringValue ?? ""
    t.check(recording.files.contains(downloaded), "the download is in the copy: \(downloaded)")
    t.equal(try? Data(contentsOf: URL(fileURLWithPath: downloaded)),
            try? Data(contentsOf: folder.appendingPathComponent("page.html")))
    t.equal(skin.measure(named: "MeasurePage")?.stringValue, "Side effects")
    // The icons are in the copy, where the skin's Image meters find them by the measures' paths.
    for (measure, bytes) in [("MeasureIcon", "icon-ico"), ("MeasureIconPath", "icon-png")] {
        let path = skin.measure(named: measure)?.stringValue ?? ""
        t.check(recording.files.contains(path), "\(measure) is in the copy: \(path)")
        t.equal(try? String(contentsOfFile: path, encoding: .utf8), bytes)
    }
    t.equal(recording.files.copy(of: dir + "/icon1.ico"), skin.measure(named: "MeasureIcon")?.stringValue)
    t.check(recording.files.copy(of: dir + "/WebParserDump.txt").map { FileManager.default.fileExists(atPath: $0) }
                == true, "the dump is in the copy")
    skin.update()
    t.equal(skin.measure(named: "MeasureScript")?.stringValue, "touched")
    t.equal(recording.records.count, expected.count, "an update does nothing outside the skin")
    t.equal(recording.files.copy(of: dir + "/new.txt"), nil, "the script's file was renamed away and removed")

    // A reload that reads the recording's copies sees what !WriteKeyValue wrote; the real files still say 0.
    skin.close()
    let again = Skin(config: "Engine\\SideEffects", fileURL: ini, skinsDirectory: skins, system: FakeSystem(),
                     host: host)
    again.sideEffects = recording
    again.sourceProvider = recording
    try again.load()
    t.equal(again.variable("Count"), "5")
    t.equal(again.variable("Theme"), "dark", "an included file's copy is read too")
    t.check(again.runtimeVariables.contains(SkinVariable(name: "count", value: "5")))
    again.close()
    t.equal(snapshot(skins), before, "and still nothing changed on disk")
}

private func studioPolicy(_ t: TestRunner) throws {
    let policy = StudioActionPolicy()
    let (skin, _) = try makeSkin(t, "[Rainmeter]\nUpdate=1000\n")
    t.check(skin.sideEffects === LiveSideEffects.shared, "live by default")
    skin.actionPolicy = policy
    t.check(skin.sideEffects is RecordingSideEffects, "the policy's side effects")
    t.check(skin.sideEffects.fileSandbox === policy.fileSandbox, "its scripts' sandbox is the recording's")
    let other = RecordingSideEffects()
    skin.sideEffects = other
    t.check(skin.sideEffects !== other, "a policy's own side effects win")
    skin.actionPolicy = nil
    t.check(skin.sideEffects === other, "without it, the ones set on the skin")
    // What the recording keeps reaches the policy's list: a file as the Studio shows it, the rest as an effect.
    policy.sideEffects?.perform(.mediaKey("PlayPause")) { t.check(false, "not run") }
    _ = policy.sideEffects?.destination(forWriting: URL(fileURLWithPath: "/tmp/x/DownloadFile/a.png"))
    t.equal(policy.recorded.map(\.kind), [.effect, .file])
    t.equal(policy.recorded.map(\.text), ["MediaKey PlayPause", "write /tmp/x/DownloadFile/a.png"])

    // The recording keeps no more than the policy does (a widget whose script saves a file at every update would
    // otherwise grow the Studio for as long as it stays open), and clearing the policy's list clears it too.
    let recording = policy.sideEffects as? RecordingSideEffects
    t.equal(recording?.limit, policy.limit, "bounded like the policy's list")
    policy.limit = 5
    t.equal(recording?.limit, 5, "and follows it")
    for i in 0..<40 { recording?.perform(.mediaKey("Key\(i)")) { t.check(false, "not run") } }
    t.equal(recording?.records.count, 5)
    t.equal(recording?.records.last, .mediaKey("Key39"), "the last ones")
    t.equal(policy.recorded.count, 5)
    policy.clearRecorded()
    t.equal(recording?.records ?? [.mediaKey("x")], [], "cleared with the policy's list")
    t.equal(policy.recorded.count, 0)
    skin.close()
}

private func runtimeVariables(_ t: TestRunner) throws {
    let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        Update=1000
        [Variables]
        Zeta=last
        alpha=1
        Mid=#alpha#-2
        [Meter]
        Meter=String
        Text=x
        """)
    let names = skin.runtimeVariables.map(\.name)
    t.equal(names, names.sorted(), "sorted by name")
    t.check(names.contains("@") && names.contains("currentconfig"), "with the built-ins fixed at load")
    t.check(!names.contains("currentconfigx"), "not the ones that follow the window")
    func value(_ name: String) -> String? { skin.runtimeVariables.first { $0.name == name }?.value }
    t.equal(value("alpha"), "1")
    t.equal(value("mid"), "1-2", "as resolved")
    t.equal(value("zeta"), "last")
    skin.execute("[!SetVariable Alpha 7][!SetVariable New x]", from: nil)
    t.equal(value("alpha"), "7", "!SetVariable")
    t.equal(value("new"), "x", "a variable a bang made")
    t.equal(skin.runtimeVariables.first { $0.name == "new" }?.description, "new=x")

    // !WriteKeyValue and a refresh: the reloaded skin lists the value written.
    skin.execute("[!WriteKeyValue Variables Zeta written]", from: nil)
    t.equal(value("zeta"), "last", "written to the file, not to the running skin")
    let reloaded = Skin(config: skin.config, fileURL: skin.fileURL, skinsDirectory: skin.skinsDirectory,
                        system: FakeSystem(), host: FakeHost())
    try reloaded.load()
    t.equal(reloaded.runtimeVariables.first { $0.name == "zeta" }?.value, "written")
    skin.close()
    reloaded.close()
}
