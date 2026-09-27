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

    t.suite("Session: undo looks at the bytes, and puts them back") {
        let dir = t.temporaryDirectory("bytes")
        func fontSize(_ value: String, _ url: URL) -> EditOp {
            .setValue(file: url, section: "M", key: "FontSize", value: value, afterIncludes: false)
        }

        // The same text saved elsewhere in another encoding (VS Code's "Save with Encoding"): the step is not undone
        // over it, as the editor always refused ("changed in another app").
        let probe = dir.appendingPathComponent("Probe.ini")
        let text = "[Rainmeter]\r\nUpdate=1000\r\n[M]\r\nFontSize=12\r\n"
        try (Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!).write(to: probe)
        let buffers = SourceBuffers()
        let sync = DiskSync(buffers: buffers)
        let step = try IniBackend.plan([fontSize("20", probe)], in: buffers)
        try buffers.apply(step)
        try sync.flush()
        let edited = text.replacingOccurrences(of: "=12", with: "=20")
        try Data(edited.utf8).write(to: probe)
        t.equal(sync.adoptChanges().map(SourceFileID.init), [SourceFileID(probe)], "another app saved it as UTF-8")
        t.equal(buffers.buffer(probe)?.text, edited, "the same text")
        t.equal(buffers.buffer(probe)?.encoding, .utf8(bom: false))
        do {
            try buffers.apply(step, reverse: true)
            t.check(false, "undone over another app's conversion")
        } catch {
            t.equal(error as? SourceBuffers.Failure, .changedElsewhere(SourceFileID(probe).url))
        }
        t.equal(try Data(contentsOf: probe), Data(edited.utf8), "the other app's file is left alone")
        t.check(!sync.hasUnwrittenChanges)
        // Only the BOM dropped is a change too.
        let bom = dir.appendingPathComponent("Bom.ini")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: bom)
        let bomStep = try IniBackend.plan([fontSize("20", bom)], in: buffers)
        try buffers.apply(bomStep)
        try sync.flush()
        try Data(edited.utf8).write(to: bom)
        sync.adoptChanges()
        t.throwsError("the BOM dropped elsewhere") { try buffers.apply(bomStep, reverse: true) }

        // Bytes that do not survive decoding (a stray Windows-1252 "°" in a UTF-8 file with a BOM): the step writes the
        // text as IniWriter always wrote it; undoing it puts the original bytes back exactly, and redo the step's.
        let ansi = dir.appendingPathComponent("Ansi.ini")
        let raw = Data([0xEF, 0xBB, 0xBF]) + Data("; 20".utf8) + Data([0xB0]) + Data("C\r\n[M]\r\nFontSize=12\r\n".utf8)
        try raw.write(to: ansi)
        t.check(try buffers.text(of: ansi).contains("\u{FFFD}"), "decoded with a replacement character")
        let lossy = try IniBackend.plan([fontSize("13", ansi)], in: buffers)
        t.check(lossy.first?.exactBefore == raw, "the original bytes are kept with the step")
        try buffers.apply(lossy)
        try sync.flush()
        let stepBytes = try Data(contentsOf: ansi)
        t.check(stepBytes != raw && String(decoding: stepBytes, as: UTF8.self).contains("FontSize=13"), "written")
        try buffers.apply(lossy, reverse: true)
        try sync.flush()
        t.equal(try Data(contentsOf: ansi), raw, "undo: byte for byte")
        t.equal(sync.changedOnDisk(), [], "what undo wrote is what the buffer knows")
        try buffers.apply(lossy)
        try sync.flush()
        t.equal(try Data(contentsOf: ansi), stepBytes, "redo: the step's bytes")
        // A later step on the restored bytes keeps them too.
        try buffers.apply(lossy, reverse: true)
        try sync.flush()
        let again = try IniBackend.plan([fontSize("14", ansi)], in: buffers)
        try buffers.apply(again)
        try sync.flush()
        try buffers.apply(again, reverse: true)
        try sync.flush()
        t.equal(try Data(contentsOf: ansi), raw, "undo of a step made on the restored bytes")

        // Typed code for a file deleted meanwhile (a git checkout, the Trash): saved as a new file, as the editor always
        // saved it; its undo leaves the file empty (the editor wrote back empty bytes), and redo writes it again.
        let styles = dir.appendingPathComponent("Styles.inc")
        try "[S]\nA=1\n".write(to: styles, atomically: true, encoding: .utf8)
        _ = try buffers.load(styles)
        try FileManager.default.removeItem(at: styles)
        sync.adoptChanges()
        t.check(!buffers.contains(styles), "forgotten")
        let typed = try IniBackend.plan([.editSource(file: styles, text: "[S]\nA=2\n", encoding: .utf8(bom: false))],
                                        in: buffers)
        t.equal(typed.count, 1, "a change")
        try buffers.apply(typed)
        try sync.flush()
        t.equal(try String(contentsOf: styles, encoding: .utf8), "[S]\nA=2\n", "created again")
        try buffers.apply(typed, reverse: true)
        try sync.flush()
        t.equal(try Data(contentsOf: styles), Data(), "undo: empty")
        try buffers.apply(typed)
        try sync.flush()
        t.equal(try String(contentsOf: styles, encoding: .utf8), "[S]\nA=2\n", "redo")
        // In a file's own encoding with a BOM: the BOM is written with the text, and undo still leaves nothing.
        let wide = dir.appendingPathComponent("Wide.inc")
        let wideStep = try IniBackend.plan([.editSource(file: wide, text: "[S]\r\n",
                                                         encoding: .utf16LittleEndian(bom: true))], in: buffers)
        try buffers.apply(wideStep)
        try sync.flush()
        t.equal(try Data(contentsOf: wide), Data([0xFF, 0xFE]) + "[S]\r\n".data(using: .utf16LittleEndian)!)
        try buffers.apply(wideStep, reverse: true)
        try sync.flush()
        t.equal(try Data(contentsOf: wide), Data(), "undo: empty")
        // A visual edit of a file that is not there still refuses.
        t.throwsError("a missing file for a visual edit") {
            _ = try IniBackend.plan([fontSize("9", dir.appendingPathComponent("Missing.inc"))], in: buffers)
        }
        t.check(!buffers.contains(dir.appendingPathComponent("Missing.inc")), "and holds nothing for it")

        // A file saved again with the same bytes, or only touched: found by its date, once (the Studio reloads the
        // widget for it, as it did when it looked at the dates); a change of the bytes is `changedOnDisk`'s.
        let touched = dir.appendingPathComponent("Touched.ini")
        try "[A]\nX=1\n".write(to: touched, atomically: true, encoding: .utf8)
        _ = try buffers.load(touched)
        t.equal(sync.touchedOnDisk([touched]), [], "not touched yet")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(40)], ofItemAtPath: touched.path)
        t.equal(sync.touchedOnDisk([touched]).map(SourceFileID.init), [SourceFileID(touched)], "touched")
        t.equal(sync.touchedOnDisk([touched]), [], "reported once")
        t.equal(sync.changedOnDisk([touched]), [], "the same bytes")
        try "[A]\nX=2\n".write(to: touched, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(50)], ofItemAtPath: touched.path)
        t.equal(sync.touchedOnDisk([touched]), [], "other bytes are not a touch")
        t.equal(sync.changedOnDisk([touched]).map(SourceFileID.init), [SourceFileID(touched)])
        sync.adoptChanges()
        t.equal(sync.touchedOnDisk([touched]), [], "adopted with its date")
        // Taken as seen (a widget's own write of the same bytes): no touch.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: touched.path)
        sync.restamp()
        t.equal(sync.touchedOnDisk([touched]), [], "restamped")
        // The session's own write is no touch either.
        try buffers.apply(try IniBackend.plan([.setValue(file: touched, section: "A", key: "X", value: "3",
                                                          afterIncludes: false)], in: buffers))
        try sync.flush()
        t.equal(sync.touchedOnDisk([touched]), [], "its own write")
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

    t.suite("Session: a new instance mirrors the graphs and the counter of the running one") {
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
            AutoScale=1
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
        fresh.mirrorCounter(of: running)
        fresh.update()
        t.equal(fresh.measure(named: "MeasureCount")?.value, running.measure(named: "MeasureCount")?.value,
                "the first update computes the counter the running one's last update did")
        t.equal(fresh.counter, running.counter, "and then counts as far")
        fresh.takeGraphs(from: running)
        guard let graph = fresh.meter(named: "Graph") as? LineMeter, let was = running.meter(named: "Graph") as? LineMeter,
              let bars = fresh.meter(named: "Bars") as? HistogramMeter,
              let barsWere = running.meter(named: "Bars") as? HistogramMeter else { return t.check(false, "meters") }
        t.equal(graph.lines.map { $0.history.count }, [5, 5], "every line's samples")
        t.equal((0..<5).map { graph.lines[0].history.value(age: $0) }, [50, 40, 30, 20, 10], "newest first")
        t.equal((0..<5).map { graph.lines[1].history.value(age: $0) }, (0..<5).map { was.lines[1].history.value(age: $0) })
        t.equal([graph.rangeMin, graph.rangeMax], [was.rangeMin, was.rangeMax], "the AutoScale range follows the samples")
        t.equal((0..<5).map { bars.primaryHistory.value(age: $0) }, (0..<5).map { barsWere.primaryHistory.value(age: $0) })
        system.cpu = 60
        fresh.update()
        t.equal(graph.lines[0].history.value(age: 0), 60, "and the graph goes on from there")
        t.equal(graph.lines[0].history.value(age: 1), 50)
        t.equal(fresh.counter, running.counter + 1)
        // A meter of another kind under the same name takes nothing.
        let other = try makeSkin(t, ini.replacingOccurrences(of: "[Other]\nMeter=Line", with: "[Other]\nMeter=Histogram"),
                                 system: system).0
        other.update()
        other.takeGraphs(from: running)
        t.equal((other.meter(named: "Other") as? HistogramMeter)?.primaryHistory.count, 1, "its own sample only")
        // A skin that never updated: the new one starts at 0 too.
        let idle = try makeSkin(t, ini, system: system).0
        let mirror = try makeSkin(t, ini, system: system).0
        mirror.mirrorCounter(of: idle)
        mirror.update()
        t.equal(mirror.counter, 1)
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

    t.suite("Session: the Studio's instance follows the input the widget on the desktop takes") {
        let ini = """
            [Rainmeter]
            [Variables]
            Theme=light
            [Tab2]
            Meter=Image
            SolidColor=0,0,0
            W=20
            H=20
            LeftMouseUpAction=[!HideMeterGroup Page1][!ShowMeterGroup Page2][!SetVariable Theme dark][!WriteKeyValue Variables Theme dark]
            MouseOverAction=[!SetOption Tab2 SolidColor 255,0,0][!UpdateMeter Tab2]
            MouseLeaveAction=[!SetOption Tab2 SolidColor 0,0,0][!UpdateMeter Tab2]
            [P1]
            Meter=String
            Y=30
            Text=one
            Group=Page1
            [P2]
            Meter=String
            Y=30
            Text=two
            Group=Page2
            Hidden=1
            """
        let (desktop, _) = try makeSkin(t, ini)
        let studioHost = FakeHost()
        let studio = Skin(config: desktop.config, fileURL: desktop.fileURL, skinsDirectory: desktop.skinsDirectory,
                          system: FakeSystem(), host: studioHost)
        let policy = StudioActionPolicy()
        studio.actionPolicy = policy
        try studio.load()
        studio.update()
        desktop.update()
        var mirrored = 0
        desktop.inputMirror = { input in
            mirrored += 1
            studio.replay(input)
        }
        desktop.mouseMoved(x: 5, y: 5)
        t.equal(studio.meter(named: "Tab2")?.rawOption("SolidColor"), "255,0,0", "a hover on the desktop shows in the Studio")
        desktop.mouseEvent(.leftUp, x: 5, y: 5)
        t.equal(studio.meter(named: "P2")?.hidden, false, "a click turns the page there too")
        t.equal(studio.meter(named: "P1")?.hidden, true)
        t.equal(studio.variable("Theme"), "dark", "and picks the theme")
        t.equal(policy.recorded.map(\.name), ["writekeyvalue"], "its file write is left to the desktop copy")
        desktop.mouseExited()
        t.equal(studio.meter(named: "Tab2")?.rawOption("SolidColor"), "0,0,0", "the hover ends")
        // A bang another widget sent, a context menu item, what was typed into InputText.
        desktop.performSent(Bang(name: "setvariable", args: ["Theme", "blue"]))
        t.equal(studio.variable("Theme"), "blue", "a bang from another widget")
        desktop.executeInput("[!SetVariable Theme green]", from: desktop.rainmeterSection)
        t.equal(studio.variable("Theme"), "green", "an action run for the person")
        // What the desktop copy runs by itself is not passed on: the Studio's instance runs its own.
        let count = mirrored
        desktop.execute("[!SetVariable Theme red]", from: nil)
        desktop.update()
        t.equal(mirrored, count, "nothing passed on")
        t.equal(studio.variable("Theme"), "green")
        // No mirror (the widget with no Studio open): input works as before.
        desktop.inputMirror = nil
        desktop.mouseMoved(x: 5, y: 5)
        t.equal(desktop.meter(named: "Tab2")?.rawOption("SolidColor"), "255,0,0")
        t.equal(studio.meter(named: "Tab2")?.rawOption("SolidColor"), "0,0,0")
        studio.close()
    }

    t.suite("Session: the Studio's instance writes files in a copy of its own") {
        let skins = t.temporaryDirectory("sandbox").appendingPathComponent("Skins")
        let dir = skins.appendingPathComponent("Root/Sub")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("img"), withIntermediateDirectories: true)
        let ini = """
            [Rainmeter]
            [Variables]
            @Include=Gen.inc
            [MeasureScript]
            Measure=Script
            ScriptFile=s.lua
            [MeasureLogo]
            Measure=WebParser
            URL=file://#CURRENTPATH#img/logo.png
            Download=1
            DownloadFile=logo.png
            [M]
            Meter=String
            MeasureName=MeasureScript
            """
        // A script that writes an included file on load (with what changes from load to load), keeps a log, clears a
        // cache and renames a file — what the Studio's instance must not do to the widget's files a second time.
        let lua = """
            function Initialize()
              local f = io.open(SKIN:MakePathAbsolute('Gen.inc'), 'w')
              f:write('[Variables]\\nGen=' .. os.time() .. '\\n')
              f:close()
              local a = io.open(SKIN:MakePathAbsolute('log.txt'), 'a')
              a:write('second\\n')
              a:close()
              local r = io.open(SKIN:MakePathAbsolute('log.txt'), 'r')
              readBack = r:read('*a')
              r:close()
              removed = tostring(os.remove(SKIN:MakePathAbsolute('cache.txt')))
              gone = tostring(io.open(SKIN:MakePathAbsolute('cache.txt'), 'r'))
              renamed = tostring(os.rename(SKIN:MakePathAbsolute('old.txt'), SKIN:MakePathAbsolute('new.txt')))
              local n = io.open(SKIN:MakePathAbsolute('new.txt'), 'r')
              moved = n and n:read('*a') or 'none'
              if n then n:close() end
              io.output(SKIN:MakePathAbsolute('out.txt'))
              io.write('x')
              io.close()
              os.execute('open https://example.com')
            end
            function Update() return readBack .. '|' .. removed .. '|' .. gone .. '|' .. renamed .. '|' .. moved end
            """
        let files: [String: String] = ["Skin.ini": ini, "s.lua": lua, "Gen.inc": "[Variables]\nGen=0\n",
                                       "log.txt": "first\n", "cache.txt": "cached", "old.txt": "old", "img/logo.png": "LOGO"]
        func reset() throws {
            for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            for name in ["new.txt", "out.txt", "DownloadFile"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        }
        func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
        func load(_ policy: SkinActionPolicy?) throws -> Skin {
            let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                            system: FakeSystem(), host: host)
            skin.actionPolicy = policy
            try skin.load()
            skin.update()
            let deadline = Date().addingTimeInterval(10)
            while (skin.measure(named: "MeasureLogo") as? WebParserMeasure)?.isDownloading == true, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            return skin
        }
        let host = FakeHost()
        try reset()
        let policy = StudioActionPolicy()
        let studio = try load(policy)
        t.equal(read("Gen.inc"), "[Variables]\nGen=0\n", "the included file is left alone")
        t.equal(read("log.txt"), "first\n", "nothing appended")
        t.equal(read("cache.txt"), "cached", "nothing removed")
        t.equal(read("old.txt"), "old", "nothing renamed")
        t.equal(read("new.txt"), nil)
        t.equal(read("out.txt"), nil, "io.output wrote nothing")
        t.equal(read("DownloadFile/logo.png"), nil, "the download is not saved in the widget's folder")
        t.equal(studio.measure(named: "MeasureScript")?.stringValue, "first\nsecond\n|true|nil|true|old",
                "the script goes on as it would: it reads back what it wrote, removed and renamed")
        let saved = studio.measure(named: "MeasureLogo")?.stringValue ?? ""
        t.check(saved.hasPrefix(policy.fileSandbox!.directory.path), "the download is in the copy: \(saved)")
        t.equal(try? String(contentsOfFile: saved, encoding: .utf8), "LOGO")
        t.equal(policy.recorded.filter { $0.kind == .file }.map(\.name), ["write", "write", "remove", "rename", "write", "write"],
                "each recorded: \(policy.recorded.map(\.text))")
        t.check(policy.recorded.contains { $0.text.hasSuffix("Gen.inc") && $0.kind == .file })
        t.check(policy.recorded.contains { $0.kind == .execute && $0.name == "https://example.com" },
                "os.execute opening a page is recorded like an action's")
        t.equal(host.executed.count, 0, "and not opened")
        // A new instance starts from the real files again.
        policy.resetFiles()
        t.check(!policy.fileSandbox!.holdsChange(of: dir.appendingPathComponent("log.txt").path), "forgotten")
        studio.close()

        // The widget on the desktop (no policy) writes for real, as before.
        let desktop = try load(nil)
        t.check(read("Gen.inc")?.hasPrefix("[Variables]\nGen=") == true && read("Gen.inc") != "[Variables]\nGen=0\n",
                "written")
        t.equal(read("log.txt"), "first\nsecond\n")
        t.equal(read("cache.txt"), nil)
        t.equal(read("new.txt"), "old")
        t.equal(read("out.txt"), "x")
        t.equal(read("DownloadFile/logo.png"), "LOGO")
        t.equal(host.executed.count, 1, "the page opens")
        desktop.close()
    }
}
