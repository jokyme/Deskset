import Foundation
@testable import DesksetCore

// The editing session's Core parts: text edits, the source buffers, the INI backend, the disk sync, loading a skin
// from memory and the Studio's action policy.

func runSessionTests(_ t: TestRunner) {
    t.suite("Session: text edits") {
        func roundTrip(_ a: String, _ b: String, _ message: String) {
            guard let edit = TextEdit.between(a, b) else { return t.equal(a, b, "no edit only for equal texts: \(message)") }
            t.equal(edit.applied(to: a), b, "forward: \(message)")
            t.equal(edit.inverse(in: a).applied(to: b), a, "back: \(message)")
        }
        t.equal(TextEdit.between("abc", "abc"), nil)
        t.equal(TextEdit.between("FontSize=12\r\n", "FontSize=13\r\n"), TextEdit(range: 10..<11, replacement: "3"),
                "only the digit that differs")
        t.equal(TextEdit.between("[A]\nX=1\n", "[A]\nX=1\nY=2\n"), TextEdit(range: 8..<8, replacement: "Y=2\n"))
        roundTrip("", "[A]\n", "from nothing")
        roundTrip("[A]\n", "", "to nothing")
        roundTrip("aaa", "aaaa", "repeated characters")
        roundTrip("Text=😀\n", "Text=😃\n", "an emoji (a surrogate pair) is never split")
        let split = TextEdit.between("x😀y", "x😃y")
        t.equal(split?.range, 1..<3, "the whole pair")
        roundTrip("Größe=1\r\n", "Größe=2\r\nNeu=ü\r\n", "non-ASCII and CRLF")
        // Random edits of a random text: forward and back always meet.
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("[]=;\r\nabcXYZ 0123😀é")
        for _ in 0..<200 {
            let a = String((0..<Int.random(in: 0...20, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            let b = String((0..<Int.random(in: 0...20, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            roundTrip(a, b, "random \(a.debugDescription) → \(b.debugDescription)")
        }
        t.equal(TextDigest("abc"), TextDigest("abc"))
        t.check(TextDigest("abc") != TextDigest("abd"))
        t.check(TextDigest("ab") != TextDigest("abc"))
    }

    t.suite("Session: source buffers") {
        let dir = t.temporaryDirectory("buffers")
        let url = dir.appendingPathComponent("Skin.ini")
        let original = "[Rainmeter]\r\nUpdate=1000\r\n[M]\r\nText=Größe\r\n"
        let bytes = Data([0xFF, 0xFE]) + original.data(using: .utf16LittleEndian)!
        try bytes.write(to: url)
        let buffers = SourceBuffers()
        t.check(!buffers.contains(url))
        t.equal(buffers.sourceText(for: url), nil, "not held: the loader reads the disk")
        let buffer = try buffers.load(url)
        t.equal(buffer.text, original, "decoded as TextDecoding does, line endings kept")
        t.equal(buffer.encoding, .utf16LittleEndian(bom: true))
        t.equal(buffer.data, bytes, "written back unchanged: the same bytes")
        t.check(!buffer.isDirty)
        // Another spelling of the same file: letter case, `..`, a symlink.
        let link = dir.appendingPathComponent("Link.ini")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        t.equal(buffers.sourceText(for: dir.appendingPathComponent("skin.INI")), original, "any letter case")
        t.equal(buffers.sourceText(for: dir.appendingPathComponent("x/../Skin.ini")), original, "..")
        t.equal(buffers.sourceText(for: link), original, "a symlink")
        t.equal(buffers.files.count, 1)
        do {
            try buffers.load(dir.appendingPathComponent("Missing.ini"))
            t.check(false, "a missing file throws")
        } catch {
            t.equal(error as? IniWriterError, .fileNotFound(dir.appendingPathComponent("Missing.ini").path))
        }

        // A change goes forward and back; each side only on the text it starts from.
        let edited = original.replacingOccurrences(of: "1000", with: "500")
        guard let change = SourceChange(file: SourceFileID(url), before: original, after: edited,
                                        encodingBefore: buffer.encoding, encodingAfter: buffer.encoding) else {
            return t.check(false, "a change")
        }
        try buffers.apply([change])
        t.equal(buffers.buffer(url)?.text, edited)
        t.check(buffers.buffer(url)?.isDirty == true, "not written yet")
        t.equal(buffers.dirtyFiles, [SourceFileID(url)])
        t.throwsError("applied twice: the text is no longer the one it starts from") { try buffers.apply([change]) }
        t.equal(buffers.buffer(url)?.text, edited, "and nothing changed")
        try buffers.apply([change], reverse: true)
        t.equal(buffers.buffer(url)?.text, original, "undone")
        t.throwsError("undone twice") { try buffers.apply([change], reverse: true) }

        // All or nothing: one file that changed elsewhere stops the whole step.
        let other = dir.appendingPathComponent("Other.inc")
        try "[Variables]\nA=1\n".write(to: other, atomically: true, encoding: .utf8)
        let otherChange = SourceChange(file: SourceFileID(other), before: "[Variables]\nA=1\n", after: "[Variables]\nA=2\n",
                                       encodingBefore: .utf8(bom: false), encodingAfter: .utf8(bom: false))!
        let stale = SourceChange(file: SourceFileID(url), before: "stale", after: "newer",
                                 encodingBefore: buffer.encoding, encodingAfter: buffer.encoding)!
        t.throwsError { try buffers.apply([otherChange, stale]) }
        t.equal(try buffers.text(of: other), "[Variables]\nA=1\n", "the good file was not changed either")
        buffers.forget(other)
        t.check(!buffers.contains(other))
        // A file that is gone cannot be undone into, and says so as the editor always did.
        try FileManager.default.removeItem(at: other)
        do {
            try buffers.apply([otherChange])
            t.check(false, "a file that is gone throws")
        } catch {
            t.equal(error as? SourceBuffers.Failure, .unreadable(SourceFileID(other).url))
            t.equal("\(error)", "cannot read Other.inc")
        }
    }

    t.suite("Session: the INI backend writes what IniWriter writes") {
        let dir = t.temporaryDirectory("backend")
        let main = dir.appendingPathComponent("Skin.ini")
        let inc = dir.appendingPathComponent("Shared.inc")
        let mainText = "; top\r\n[Rainmeter]\r\nUpdate=1000\r\n\r\n[Variables]\r\n@Include=Shared.inc\r\nColor=1,2,3\r\n\r\n"
            + "[MeterA]\r\nMeter=String\r\nText=A\r\n\r\n[MeterB]\r\nMeter=String\r\nText=B\r\n"
        let incText = "[Variables]\nColor=9,9,9\nSize=12\n\n[MeterB]\nFontSize=20\n"
        func reset() throws {
            try mainText.write(to: main, atomically: true, encoding: .utf8)
            try incText.write(to: inc, atomically: true, encoding: .utf8)
        }
        /// The text `ops` make in memory, next to what the file versions write for `write`.
        func compare(_ ops: [EditOp], _ message: String, write: () throws -> Void) throws {
            try reset()
            let buffers = SourceBuffers()
            let changes = try IniBackend.plan(ops, in: buffers)
            try buffers.apply(changes)
            let memory = [main, inc].map { buffers.buffer($0)?.data ?? (try? Data(contentsOf: $0)) ?? Data() }
            try reset()
            try write()
            let disk = [main, inc].map { (try? Data(contentsOf: $0)) ?? Data() }
            t.equal(memory, disk, message)
            t.check(!changes.isEmpty || memory == [Data(mainText.utf8), Data(incText.utf8)], "\(message): a change")
        }
        try compare([.setValue(file: main, section: "MeterA", key: "FontSize", value: "14", afterIncludes: false)],
                    "a new key") {
            try IniWriter.writeValue("14", key: "FontSize", section: "MeterA", fileURL: main)
        }
        try compare([.setValue(file: main, section: "MeterA", key: "text", value: " padded ", afterIncludes: false)],
                    "an existing key, a value with spaces") {
            try IniWriter.writeValue(" padded ", key: "text", section: "MeterA", fileURL: main)
        }
        try compare([.setValue(file: main, section: "New", key: "X", value: "1", afterIncludes: false)], "a new section") {
            try IniWriter.writeValue("1", key: "X", section: "New", fileURL: main)
        }
        try compare([.setValue(file: main, section: "Variables", key: "Color", value: "4,5,6", afterIncludes: true)],
                    "after the includes") {
            try IniWriter.writeAfterIncludes("4,5,6", key: "Color", section: "Variables", fileURL: main)
        }
        try compare([.removeKey(file: inc, section: "Variables", key: "Size")], "a key removed") {
            _ = try IniWriter.removeKey("Size", section: "Variables", fileURL: inc)
        }
        let sections = [EditorComponents.Section(name: "MeterC", options: [(key: "Meter", value: "String"),
                                                                             (key: "Text", value: "C")])]
        try compare([.appendSections(sections, file: main)], "sections added") {
            for s in sections {
                for o in s.options { try IniWriter.writeValue(o.value, key: o.key, section: s.name, fileURL: main) }
            }
        }
        try compare([.removeSection("MeterB", files: [main, inc])], "a section removed from every file") {
            try IniWriter.removeSection("MeterB", fileURL: main)
            try IniWriter.removeSection("MeterB", fileURL: inc)
        }
        try compare([.moveSection("MeterB", before: "MeterA", file: main)], "a section moved") {
            _ = try IniWriter.moveSection("MeterB", before: "MeterA", fileURL: main)
        }
        try compare([.appendSections(sections, file: main), .moveSection("MeterC", before: "MeterB", file: main)],
                    "a later edit sees what an earlier one made") {
            for s in sections {
                for o in s.options { try IniWriter.writeValue(o.value, key: o.key, section: s.name, fileURL: main) }
            }
            _ = try IniWriter.moveSection("MeterC", before: "MeterB", fileURL: main)
        }

        try reset()
        let buffers = SourceBuffers()
        t.equal(try IniBackend.plan([.moveSection("Nope", before: nil, file: main)], in: buffers).count, 0,
                "a missing section: nothing")
        t.equal(try IniBackend.plan([.setValue(file: main, section: "MeterA", key: "Text", value: "A", afterIncludes: false)],
                                    in: buffers).count, 0, "the same value: nothing")
        let two = try IniBackend.plan([.setValue(file: main, section: "MeterA", key: "X", value: "1", afterIncludes: false),
                                       .setValue(file: main, section: "MeterA", key: "Y", value: "2", afterIncludes: false),
                                       .removeKey(file: inc, section: "MeterB", key: "FontSize")], in: buffers)
        t.equal(two.map(\.file), [SourceFileID(main), SourceFileID(inc)], "one change per file, in the order they came")
        t.equal(buffers.dirtyFiles, [], "planning changes nothing")
        t.throwsError("a missing file throws, as IniWriter does") {
            _ = try IniBackend.plan([.setValue(file: dir.appendingPathComponent("No.ini"), section: "A", key: "B", value: "1",
                                              afterIncludes: false)], in: buffers)
        }
        t.throwsError("a key that could not be read back throws") {
            _ = try IniBackend.plan([.setValue(file: main, section: "A", key: "B=C", value: "1", afterIncludes: false)],
                                    in: buffers)
        }

        // An ANSI file that cannot hold the new value becomes UTF-16 LE with a BOM, as IniWriter writes it; the undo
        // gives the ANSI bytes back.
        let ansi = dir.appendingPathComponent("Ansi.ini")
        let ansiBytes = Data("[M]\r\nText=caf".utf8) + Data([0xE9]) + Data("\r\n".utf8)
        try ansiBytes.write(to: ansi)
        let ansiBuffers = SourceBuffers()
        let converted = try IniBackend.plan([.setValue(file: ansi, section: "M", key: "Text", value: "中文", afterIncludes: false)],
                                            in: ansiBuffers)
        t.equal(converted.first?.encodingBefore, .windows1252)
        t.equal(converted.first?.encodingAfter, .utf16LittleEndian(bom: true))
        try ansiBuffers.apply(converted)
        try IniWriter.writeValue("中文", key: "Text", section: "M", fileURL: ansi)
        t.equal(ansiBuffers.buffer(ansi)?.data, try Data(contentsOf: ansi), "the bytes IniWriter writes")
        try ansiBuffers.apply(converted, reverse: true)
        t.equal(ansiBuffers.buffer(ansi)?.data, ansiBytes, "undone: the ANSI bytes again")

        // Typed code: kept exactly (line endings included), in the encoding the code pane gives.
        try reset()
        let typed = SourceBuffers()
        let code = "[Rainmeter]\nUpdate=500\r\n"
        let edits = try IniBackend.plan([.editSource(file: main, text: code, encoding: nil)], in: typed)
        try typed.apply(edits)
        t.equal(typed.buffer(main)?.text, code)
        try ansiBytes.write(to: ansi)
        do {
            _ = try IniBackend.plan([.editSource(file: ansi, text: "[M]\nText=中文\n", encoding: nil)], in: SourceBuffers())
            t.check(false, "typed code an ANSI file cannot hold is refused")
        } catch {
            t.check(error is IniBackend.UnencodableText, "\(error)")
        }
        let unicode = try IniBackend.plan([.editSource(file: ansi, text: "[M]\nText=中文\n",
                                                       encoding: .utf16LittleEndian(bom: true))], in: SourceBuffers())
        t.equal(unicode.first?.encodingAfter, .utf16LittleEndian(bom: true), "converted by the code pane: accepted")
    }

    t.suite("Session: skin edits as operations") {
        let ini = """
            [Rainmeter]
            [Variables]
            @Include=#@#Vars.inc
            [StyleBig]
            FontSize=20
            [M]
            Meter=String
            MeterStyle=StyleBig
            FontSize=12
            Text=Hi
            [N]
            Meter=String
            Text=There
            """
        let (skin, _) = try makeSkin(t, ini, files: ["Root/@Resources/Vars.inc": "[Variables]\nColor=1,2,3\n[N]\nX=4\n"])
        let buffers = SourceBuffers()
        func text(_ ops: [EditOp?]) throws -> String {
            let changes = try IniBackend.plan(ops.compactMap { $0 }, in: buffers)
            guard let main = changes.first(where: { $0.file == SourceFileID(skin.fileURL) }) else { return ini }
            return main.edit.applied(to: try buffers.text(of: skin.fileURL))
        }
        t.check(try text([skin.op(settingOwnOption: "FontSize", of: "m", to: "14")]).contains("FontSize=14\nText=Hi"),
                "own option: the section itself")
        t.check(try text([skin.op(settingOption: "FontSize", of: "N", to: "9")]).contains("Text=There\nFontSize=9"),
                "an option not set yet: added to the section")
        t.check(try text([skin.op(removingOwnOption: "FontSize", of: "M")]).contains("MeterStyle=StyleBig\nText=Hi"),
                "own option removed")
        t.equal(skin.op(removingOwnOption: "Nothing", of: "M") == nil, true, "nothing to remove: no edit")
        t.check(try !text([skin.op(removingSection: "N")]).contains("[N]"), "a section removed")
        let removeN = try IniBackend.plan([skin.op(removingSection: "N")], in: buffers)
        t.equal(Set(removeN.map(\.file.url.lastPathComponent)), ["Skin.ini", "Vars.inc"], "from every file that has a block")
        t.check(try text([skin.op(movingSection: "N", before: "M")]).range(of: "[N]")!.lowerBound
                    < (try text([skin.op(movingSection: "N", before: "M")])).range(of: "[M]")!.lowerBound, "moved")
        t.equal(skin.op(movingSection: "Variables", before: "N") == nil, false)
        let sections = [EditorComponents.Section(name: "O", options: [(key: "Meter", value: "Image")])]
        t.check(try text([skin.op(appending: sections)]).hasSuffix("[O]\nMeter=Image\n"), "appended")
    }

    t.suite("Session: disk sync") {
        let dir = t.temporaryDirectory("disksync")
        let url = dir.appendingPathComponent("Skin.ini")
        let original = "[Rainmeter]\r\nUpdate=1000\r\n"
        try (Data([0xEF, 0xBB, 0xBF]) + Data(original.utf8)).write(to: url)
        let buffers = SourceBuffers()
        let sync = DiskSync(buffers: buffers)
        _ = try buffers.load(url)
        t.equal(sync.changedOnDisk(), [], "nothing changed yet")
        t.check(!sync.hasUnwrittenChanges)
        let changes = try IniBackend.plan([.setValue(file: url, section: "Rainmeter", key: "Update", value: "500",
                                                      afterIncludes: false)], in: buffers)
        try buffers.apply(changes)
        t.check(sync.hasUnwrittenChanges)
        t.equal(try sync.flush().map(SourceFileID.init), [SourceFileID(url)], "written")
        let written = try Data(contentsOf: url)
        t.equal(written, Data([0xEF, 0xBB, 0xBF]) + Data("[Rainmeter]\r\nUpdate=500\r\n".utf8), "BOM and CRLF kept")
        t.check(!sync.hasUnwrittenChanges)
        t.equal(sync.changedOnDisk(), [], "its own write is not a change made elsewhere")
        t.equal(try sync.flush(), [], "nothing left to write")

        // Saved elsewhere, even keeping the modification date and the size: found by the bytes.
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let elsewhere = Data([0xEF, 0xBB, 0xBF]) + Data("[Rainmeter]\r\nUpdate=900\r\n".utf8)
        try elsewhere.write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        t.equal(sync.changedOnDisk().map(SourceFileID.init), [SourceFileID(url)], "another app's save")
        t.equal(sync.adoptChanges().map(SourceFileID.init), [SourceFileID(url)])
        t.equal(buffers.buffer(url)?.text, "[Rainmeter]\r\nUpdate=900\r\n", "the clean buffer takes it")
        t.equal(sync.changedOnDisk(), [])
        // The same bytes saved again: nothing to take.
        try elsewhere.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: url.path)
        t.equal(sync.changedOnDisk(), [], "the same bytes are no change")
        // A buffer with edits of its own keeps them.
        try buffers.apply(try IniBackend.plan([.setValue(file: url, section: "Rainmeter", key: "Update", value: "1",
                                                          afterIncludes: false)], in: buffers))
        try Data("[Rainmeter]\r\nUpdate=2\r\n".utf8).write(to: url)
        t.equal(sync.adoptChanges(), [], "edits are not dropped")
        t.equal(buffers.buffer(url)?.text, "[Rainmeter]\r\nUpdate=1\r\n")
        try sync.flush()
        t.equal(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF]) + Data("[Rainmeter]\r\nUpdate=1\r\n".utf8),
                "whoever writes them decides (here: the session)")
        // A file that is gone is forgotten.
        try FileManager.default.removeItem(at: url)
        t.equal(sync.adoptChanges().map(SourceFileID.init), [SourceFileID(url)])
        t.check(!buffers.contains(url), "forgotten: its next use reads the disk")
        // A write that fails keeps the text (dirty) and says why.
        let locked = dir.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = locked.appendingPathComponent("Skin.ini")
        try "[A]\nX=1\n".write(to: file, atomically: true, encoding: .utf8)
        try buffers.apply(try IniBackend.plan([.setValue(file: file, section: "A", key: "X", value: "2", afterIncludes: false)],
                                              in: buffers))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        t.throwsError("a folder that cannot be written") { try sync.flush() }
        t.check(sync.hasUnwrittenChanges, "the text waits")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        try sync.flush()
        t.equal(try String(contentsOf: file, encoding: .utf8), "[A]\nX=2\n", "written once it can be")

        // A write after a pause: several edits, one write.
        let later = dir.appendingPathComponent("Later.ini")
        try "[A]\nX=1\n".write(to: later, atomically: true, encoding: .utf8)
        let queue = DispatchQueue(label: "disk sync test")
        sync.queue = queue
        sync.idleDelay = 0.05
        for value in ["2", "3"] {
            try queue.sync {
                try buffers.apply(try IniBackend.plan([.setValue(file: later, section: "A", key: "X", value: value,
                                                                  afterIncludes: false)], in: buffers))
                sync.scheduleFlush()
            }
        }
        t.check(queue.sync { sync.hasScheduledFlush }, "waiting for the pause")
        let deadline = Date().addingTimeInterval(5)
        while queue.sync(execute: { sync.hasScheduledFlush }), Date() < deadline { usleep(10_000) }
        t.equal(try String(contentsOf: later, encoding: .utf8), "[A]\nX=3\n", "written after the pause")
    }

    t.suite("Session: a skin loads from the text in memory") {
        let ini = "[Rainmeter]\n[Variables]\n@Include=#@#Vars.inc\n[M]\nMeter=String\nText=#Word#\nFontSize=10\n"
        let (skin, host) = try makeSkin(t, ini, files: ["Root/@Resources/Vars.inc": "[Variables]\nWord=disk\n"])
        t.equal(skin.variable("Word"), "disk")
        let buffers = SourceBuffers()
        let changes = try IniBackend.plan([
            .setValue(file: skin.fileURL, section: "M", key: "FontSize", value: "30", afterIncludes: false),
            .setValue(file: skin.includedFiles[0], section: "Variables", key: "Word", value: "memory", afterIncludes: false),
        ], in: buffers)
        try buffers.apply(changes)
        let studio = Skin(config: skin.config, fileURL: skin.fileURL, skinsDirectory: skin.skinsDirectory,
                          system: FakeSystem(), host: host)
        studio.sourceProvider = buffers
        try studio.load()
        studio.update()
        t.equal(studio.variable("Word"), "memory", "the include from memory")
        t.equal(studio.meter(named: "M")?.rawOption("FontSize"), "30", "the skin file from memory")
        t.check(try String(contentsOf: skin.fileURL, encoding: .utf8).contains("FontSize=10"), "the disk is untouched")
        t.equal(studio.sourceText(of: skin.includedFiles[0]), "[Variables]\nWord=memory\n")
        t.equal(studio.sharedDefinition(ofVariable: "Word"), studio.includedFiles.first, "lookups read the memory too")
        // A section added in memory only.
        try buffers.apply(try IniBackend.plan([studio.op(appending: [EditorComponents.Section(
            name: "Extra", options: [(key: "Meter", value: "String")])])], in: buffers))
        try studio.load()
        t.check(studio.meter(named: "Extra") != nil)
        t.equal(studio.definingFiles(ofSection: "Extra").map(\.lastPathComponent), ["Skin.ini"])
        t.equal(skin.definingFiles(ofSection: "Extra").count, 1, "(the disk copy has only its header file)")
    }

    t.suite("Session: a new instance takes the graphs and the counter of the running one") {
        let ini = """
            [Rainmeter]
            [MeasureCPU]
            Measure=CPU
            [MeasureCount]
            Measure=Calc
            Formula=Counter
            [Graph]
            Meter=Line
            MeasureName=MeasureCPU
            MeasureName2=MeasureCount
            LineCount=2
            W=20
            H=10
            [Bars]
            Meter=Histogram
            MeasureName=MeasureCPU
            W=20
            H=10
            [Other]
            Meter=Line
            MeasureName=MeasureCPU
            W=20
            H=10
            """
        let system = FakeSystem()
        let (running, host) = try makeSkin(t, ini, system: system)
        for i in 0..<5 {
            system.cpu = Double(10 * (i + 1))
            running.update()
        }
        let fresh = Skin(config: running.config, fileURL: running.fileURL, skinsDirectory: running.skinsDirectory,
                         system: system, host: host)
        try fresh.load()
        fresh.seed(from: running)
        guard let graph = fresh.meter(named: "Graph") as? LineMeter, let was = running.meter(named: "Graph") as? LineMeter,
              let bars = fresh.meter(named: "Bars") as? HistogramMeter,
              let barsWere = running.meter(named: "Bars") as? HistogramMeter else { return t.check(false, "meters") }
        t.equal(graph.lines.map { $0.history.count }, [5, 5], "every line's samples")
        t.equal((0..<5).map { graph.lines[0].history.value(age: $0) }, [50, 40, 30, 20, 10], "newest first")
        t.equal((0..<5).map { graph.lines[1].history.value(age: $0) }, (0..<5).map { was.lines[1].history.value(age: $0) })
        t.equal((0..<5).map { bars.primaryHistory.value(age: $0) }, (0..<5).map { barsWere.primaryHistory.value(age: $0) })
        t.equal(fresh.counter, running.counter, "the counter goes on")
        system.cpu = 60
        fresh.update()
        t.equal(graph.lines[0].history.value(age: 0), 60, "and the graph goes on from there")
        t.equal(graph.lines[0].history.value(age: 1), 50)
        t.equal(fresh.counter, running.counter + 1)
        // A meter of another kind under the same name takes nothing.
        let other = try makeSkin(t, ini.replacingOccurrences(of: "[Other]\nMeter=Line", with: "[Other]\nMeter=Histogram"),
                                 system: system).0
        other.seed(from: running)
        t.equal((other.meter(named: "Other") as? HistogramMeter)?.primaryHistory.count, 0)
    }

    t.suite("Session: the Studio's instance runs what stays inside the widget") {
        let ini = """
            [Rainmeter]
            [Variables]
            Count=0
            [MeasureTimer]
            Measure=Plugin
            Plugin=ActionTimer
            ActionList1=Tick
            Tick=[!SetVariable Count 1]
            [MeasureRun]
            Measure=Plugin
            Plugin=RunCommand
            Program=/usr/bin/true
            [M]
            Meter=String
            Text=#Count#
            DynamicVariables=1
            """
        let host = FakeHost()
        let (skin, _) = try makeSkin(t, ini, host: host)
        let policy = StudioActionPolicy()
        var told: [String] = []
        policy.onRecord = { told.append($0.text) }
        skin.actionPolicy = policy
        let before = try String(contentsOf: skin.fileURL, encoding: .utf8)

        skin.execute("[!SetOption M Text x][!SetVariable Count 2][!HideMeter M][!UpdateMeter M][!Log \"hello\"]", from: nil)
        t.equal(skin.meter(named: "M")?.hidden, true, "inside the widget: runs")
        t.equal(skin.variable("Count"), "2")
        t.equal(policy.recorded, [], "nothing recorded")

        skin.execute("[!WriteKeyValue Variables Count 5][\"https://example.com\"][!Move 10 20][!ActivateConfig Other]"
                     + "[!SetVariable Count 9 Other\\Config][!Refresh][!CommandMeasure MeasureRun Run][!Quit]", from: nil)
        t.equal(try String(contentsOf: skin.fileURL, encoding: .utf8), before, "!WriteKeyValue writes nothing")
        t.equal(host.executed, [], "no web page opens")
        t.equal(host.handled.map(\.name), [], "no window or app bang reaches the host")
        t.equal(host.forwarded.count, 0, "nothing reaches another widget")
        t.equal(skin.variable("Count"), "2", "another widget's variable is not this one's")
        t.equal(policy.recorded.map(\.name), ["writekeyvalue", "https://example.com", "move", "activateconfig", "setvariable",
                                              "refresh", "commandmeasure", "quit"], "each recorded, in order")
        t.equal(policy.recorded.first?.text, "!WriteKeyValue Variables Count 5")
        t.equal(told.count, 8, "and told")

        // Its own animation timer runs; a measure it does not have is left to the engine (logged, nothing done).
        policy.clearRecorded()
        skin.execute("[!CommandMeasure MeasureTimer \"Execute 1\"][!CommandMeasure NoSuchMeasure Run]", from: nil)
        t.equal(policy.recorded, [], "ActionTimer stays inside")
        t.check(StudioActionPolicy.staysInside(Bang(name: "setoption", args: ["M", "X", "1", "*"]), in: skin),
                "* includes this widget")
        t.check(StudioActionPolicy.staysInside(Bang(name: "update", args: ["Root\\Sub"]), in: skin), "its own config")
        t.check(!StudioActionPolicy.staysInside(Bang(name: "update", args: ["Other"]), in: skin), "another config")
        t.check(!StudioActionPolicy.staysInside(Bang(name: "setvariablegroup", args: ["A", "1", "G"]), in: skin),
                "a group of widgets")
        policy.limit = 3
        for i in 0..<5 { skin.execute("[!Move \(i) 0]", from: nil) }
        t.equal(policy.recorded.map(\.text), ["!Move 2 0", "!Move 3 0", "!Move 4 0"], "the last few are kept")
        // Without a policy (the widget on the desktop) everything runs as before.
        skin.actionPolicy = nil
        skin.execute("[!Move 1 2]", from: nil)
        t.equal(host.handled.map(\.name), ["move"])
    }
}
