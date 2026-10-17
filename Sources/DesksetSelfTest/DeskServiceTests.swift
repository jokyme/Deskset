import Foundation
@testable import DeskLanguage

// The language service (positions, the open document, diagnostics, formatting and latency). Positions are checked
// against NSString, which the text view uses; results after edits against a freshly opened document and Desk.check.

/// Pieces random texts are made of: ASCII, every kind of line break, a byte order mark, surrogate pairs, CJK,
/// combining marks, a ZWJ sequence and the Unicode separators Desk does not treat as line breaks.
private let deskServicePieces = ["a", "b", "z", "{", "}", " ", "  ", "\t", "\n", "\n", "\r\n", "\r", "\u{FEFF}", "é",
                                 "e\u{301}", "中文", "日本語", "한", "😀", "👩‍👩‍👧", "🇨🇳", "𝄞", "\u{2028}", "\u{0085}",
                                 "Text(\"", "\")", "// note", "ß", "Ω"]
/// The same without U+2028, U+2029 and U+0085 (NSString's line functions treat them as line breaks).
private let deskServicePlainPieces = deskServicePieces.filter { $0 != "\u{2028}" && $0 != "\u{0085}" }

private func deskServiceRandomText(_ random: inout DeskRandom, pieces: [String], count: Int) -> String {
    var text = random.chance(30) ? "\u{FEFF}" : ""
    for _ in 0..<count { text += random.pick(pieces) }
    return text
}

/// The line and UTF-16 column of every UTF-16 offset of `s` (0…length), counting LF, CR LF and a lone CR as line
/// breaks; an offset between a CR and its LF is on the CR's line.
private func deskServiceReferenceLines(_ s: NSString) -> (lines: [Int], columns: [Int], lineCount: Int) {
    let n = s.length
    var lines = [Int](repeating: 0, count: n + 1)
    var columns = [Int](repeating: 0, count: n + 1)
    var line = 0
    var start = 0
    var i = 0
    while i <= n {
        lines[i] = line
        columns[i] = i - start
        guard i < n else { break }
        let c = s.character(at: i)
        if c == 0x0A || (c == 0x0D && !(i + 1 < n && s.character(at: i + 1) == 0x0A)) {
            line += 1
            start = i + 1
        } else if c == 0x0D {
            // CR LF: the offset between them is still on this line.
            lines[i + 1] = line
            columns[i + 1] = i + 1 - start
            line += 1
            start = i + 2
            i += 1
        }
        i += 1
    }
    return (lines, columns, line + 1)
}

/// A UTF-16 offset moved off the second half of a surrogate pair.
private func deskServiceScalarStart(_ s: NSString, _ offset: Int) -> Int {
    guard offset > 0, offset < s.length else { return max(0, min(offset, s.length)) }
    let c = s.character(at: offset)
    let before = s.character(at: offset - 1)
    return (0xDC00...0xDFFF).contains(c) && (0xD800...0xDBFF).contains(before) ? offset - 1 : offset
}

/// The UTF-16 range of a UTF-8 range, by Swift's own string views (independent of DeskTextIndex).
private func deskServiceUTF16(_ text: String, utf8 range: Range<Int>) -> Range<Int> {
    func units(_ k: Int) -> Int {
        let utf8 = text.utf8
        let index = utf8.index(utf8.startIndex, offsetBy: min(k, utf8.count))
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }
    return units(range.lowerBound)..<units(range.upperBound)
}

/// Applies a workspace edit's edits of one file to its text (UTF-16, by NSString).
private func deskServiceApply(_ edit: DeskWorkspaceEdit, file: DeskFileID, to text: String) -> String {
    DeskTextEditU16.apply(edit.edits(for: file), to: text)
}

/// The descriptions of a checked file's diagnostics (id, severity, file, UTF-8 range, arguments).
private func deskServiceDescriptions(_ diagnostics: [Diagnostic]) -> [String] {
    diagnostics.map { "\($0.file.path) \($0.description)" }
}

func runDeskServiceTests(_ t: TestRunner) {
    t.suite("Desk: service — positions") {
        var random = DeskRandom(seed: 0x5EED_2026)
        var conversions = 0
        for round in 0..<220 {
            let plain = round % 2 == 0
            let text = deskServiceRandomText(&random, pieces: plain ? deskServicePlainPieces : deskServicePieces,
                                             count: 1 + random.int(90))
            let ns = text as NSString
            let bytes = Array(text.utf8)
            let index = DeskTextIndex(text)
            let reference = deskServiceReferenceLines(ns)
            let tree = Desk.parse(text, fileName: "P.desk")
            t.equal(index.utf16Count, ns.length, "UTF-16 length (round \(round))")
            t.equal(index.utf8Count, bytes.count, "UTF-8 length (round \(round))")
            t.equal(index.lineCount, reference.lineCount, "lines (round \(round))")
            for _ in 0..<25 {
                // UTF-8 → UTF-16, from any byte (inside a scalar: that scalar's start).
                var k = random.int(bytes.count + 3) - 1
                let u16 = index.utf16Offset(ofUTF8: k)
                k = max(0, min(k, bytes.count))
                while k > 0, k < bytes.count, bytes[k] & 0xC0 == 0x80 { k -= 1 }
                let expected16 = (String(decoding: bytes[0..<k], as: UTF8.self) as NSString).length
                t.equal(u16, expected16, "UTF-16 offset of UTF-8 \(k) in \(text.debugDescription)")
                // UTF-16 → UTF-8 and line/column, from any unit (inside a surrogate pair: the pair's start).
                let u = random.int(ns.length + 3) - 1
                let clamped = deskServiceScalarStart(ns, u)
                let expected8 = (ns.substring(to: clamped) as String).utf8.count
                t.equal(index.utf8Offset(ofUTF16: u), expected8, "UTF-8 offset of UTF-16 \(u) in \(text.debugDescription)")
                let position = index.position(utf16: u)
                t.equal(position.offset, clamped, "clamped offset \(u)")
                t.equal(position.line, reference.lines[clamped], "line of \(clamped) in \(text.debugDescription)")
                t.equal(position.column, reference.columns[clamped], "column of \(clamped) in \(text.debugDescription)")
                // Back from (line, column); the offset between a CR and its LF comes back as the end of the content.
                t.equal(index.utf16Offset(line: position.line, column: position.column),
                        min(clamped, index.utf16ContentRange(ofLine: position.line).upperBound),
                        "offset of \(position) in \(text.debugDescription)")
                // NSString's own line start (only for texts without U+2028 and U+0085).
                if plain {
                    var start = 0
                    ns.getLineStart(&start, end: nil, contentsEnd: nil, for: NSRange(location: clamped, length: 0))
                    t.equal(clamped - position.column, start, "line start of \(clamped) in \(text.debugDescription)")
                }
                // The tree's SourceLocation agrees (1-based).
                let location = tree.location(of: expected8)
                t.equal(location.line - 1, position.line, "SourceLocation line")
                t.equal(location.utf16Column - 1, position.column, "SourceLocation UTF-16 column")
                conversions += 6
            }
        }
        t.check(conversions >= 10_000, "only \(conversions) conversions")
        print("    \(conversions) position conversions checked against NSString")

        // Fixed cases.
        let bom = DeskTextIndex("\u{FEFF}ab\r\ncd\ref\n😀x")
        t.equal(bom.utf16Count, 14)
        t.equal(bom.lineCount, 4)
        t.equal(bom.utf16Offset(ofUTF8: 3), 1, "after the BOM")
        t.equal(bom.utf16Offset(ofUTF8: 1), 0, "inside the BOM")
        t.equal(bom.lineAndColumn(ofUTF16: 4).line, 0, "between CR and LF")
        t.equal(bom.lineAndColumn(ofUTF16: 5).line, 1)
        t.equal(bom.lineAndColumn(ofUTF16: 8).line, 2, "after a lone CR")
        t.equal(bom.position(utf16: 12).offset, 11, "inside a surrogate pair")
        t.equal(bom.utf16Offset(line: 0, column: 99), 3, "a column past the end of the line")
        t.equal(bom.utf16Offset(line: 9, column: 0), 14, "a line past the end")
        t.equal(bom.utf16Offset(line: -1, column: 4), 0)
        t.equal(bom.utf16ContentRange(ofLine: 0), 0..<3)
        t.equal(bom.utf16Range(ofLine: 0), 0..<5)
        let empty = DeskTextIndex("")
        t.equal(empty.lineCount, 1)
        t.equal(empty.position(utf16: 5).offset, 0)
        let range = bom.range(utf16: 5..<7)
        t.equal(range.nsRange, NSRange(location: 5, length: 2))
        t.equal(bom.range(NSRange(location: 5, length: 2)), range)
        t.equal(bom.range(NSRange(location: NSNotFound, length: 0)), nil)
        t.equal(range.description, "2:1-2:3")

        // Workspace edits: sorted, never overlapping, insertions in the order given.
        let index = DeskTextIndex("abcdef")
        func edit(_ r: Range<Int>, _ s: String) -> DeskTextEditU16 { DeskTextEditU16(range: index.range(utf16: r), newText: s) }
        let file = DeskFileID("A.desk")
        let workspace = DeskWorkspaceEdit([file: [edit(4..<5, "E"), edit(1..<3, "BC"), edit(2..<4, "x"), edit(1..<1, "1"),
                                                  edit(1..<1, "2"), edit(5..<5, "!")]])
        t.equal(workspace.edits(for: file).map(\.newText), ["1", "2", "BC", "E", "!"])
        t.equal(DeskTextEditU16.apply(workspace.edits(for: file), to: "abcdef"), "a12BCdE!f")
        t.check(DeskWorkspaceEdit([file: []]).isEmpty)
    }

    t.suite("Desk: service — document") {
        var random = DeskRandom(seed: 0xD0C_2026)
        let base = "// 小组件 😀\r\n" + deskLargeWidget(lines: 60)
        let file = DeskFileID("Doc.desk")
        let service = DeskLanguageService(openFile: file, files: [file: base])
        let first = service.snapshot
        let mutable = NSMutableString(string: base)
        let inserts = ["x", "\n", "\r\n", " ", "中", "😀", "e\u{301}", "}", "{", "Text(\"A\")", ".font(.caption)", "", "\u{FEFF}"]
        var version = 0
        for step in 1...240 {
            // One to three changes per update, each range in the text the changes before it left.
            var changes: [DeskTextChange] = []
            for _ in 0..<(1 + (random.chance(20) ? random.int(3) : 0)) {
                let lower = deskServiceScalarStart(mutable, random.int(mutable.length + 1))
                let upper = deskServiceScalarStart(mutable, min(mutable.length, lower + random.int(12)))
                let range = NSRange(location: lower, length: max(0, upper - lower))
                let insert = random.pick(inserts)
                mutable.replaceCharacters(in: range, with: insert)
                changes.append(DeskTextChange(nsRange: range, text: insert))
            }
            version += 1
            let snapshot = service.update(changes: changes, version: version)
            t.equal(snapshot.text, mutable as String, "text after step \(step)")
            t.equal(snapshot.version, version)
            if step % 24 == 0 {
                // The same as a freshly opened document and a fresh check.
                let fresh = DeskLanguageService(openFile: file, files: [file: mutable as String]).snapshot
                t.equal(snapshot.diagnostics, fresh.diagnostics, "diagnostics after step \(step)")
                t.equal(snapshot.index.utf16Count, fresh.index.utf16Count)
                t.equal(snapshot.index.lineCount, fresh.index.lineCount)
                t.equal(snapshot.formatDocument(), fresh.formatDocument(), "formatting after step \(step)")
                let checked = Desk.check(Desk.parse(mutable as String, file: file))
                t.equal(deskServiceDescriptions(snapshot.checked.diagnostics), deskServiceDescriptions(checked.diagnostics),
                        "re-check after step \(step)")
            }
        }
        t.equal(first.text, base, "an old snapshot never changes")

        // Clamping: a range inside a surrogate pair or past the end.
        let clampService = DeskLanguageService(openFile: file, files: [file: "a😀b"])
        t.equal(clampService.update(changes: [DeskTextChange(range: 2..<3, text: "x")], version: 1).text, "axb",
                "a range that starts inside a pair starts at the pair")
        t.equal(clampService.update(changes: [DeskTextChange(range: 1..<1, text: "😀")], version: 2).text, "a😀xb")
        t.equal(clampService.update(changes: [DeskTextChange(range: 1..<2, text: "y")], version: 2).text, "ay😀xb",
                "a range that ends inside a pair ends at the pair's start")
        t.equal(clampService.update(changes: [DeskTextChange(range: 90..<99, text: "!")], version: 2).text, "ay😀xb!")
        let unchanged = clampService.update(changes: [], version: 3)
        t.equal(unchanged.tree.version, clampService.snapshot.tree.version)
        t.equal(unchanged.version, 3)
        t.equal(clampService.replaceText("widget { }", version: 4).text, "widget { }")

        // package.desk is checked once and reused until it changes; siblings are checked only when asked.
        let widget = DeskFileID("CPU.desk")
        let packageText = """
        package { name: "Pack" }
        options {
            accent = ColorPicker("Accent", default: .accent)
        }
        style card { .padding(8).background(.glass) }
        style unusedStyle { .padding(2) }
        """
        let widgetText = """
        info { name: "CPU" }
        widget {
            Text("{cpu.usage}%").style(card).color(options.accent)
        }
        """
        let siblingText = "info { name: \"Other\" }\nwidget { Text(\"B\").style(card) }\n"
        let folder: [DeskFileID: String] = [widget: widgetText, DeskFileID("package.desk"): packageText,
                                            DeskFileID("Other.desk"): siblingText]
        let packaged = DeskLanguageService(openFile: widget, files: folder)
        t.equal(packaged.packageChecks, 1)
        t.equal(packaged.snapshot.checked.diagnostics.filter { $0.severity == .error }.map(\.id.rawValue), [],
                "the package's style and option resolve")
        for k in 1...5 {
            packaged.update(changes: [DeskTextChange(range: 0..<0, text: "// \(k)\n")], version: k)
        }
        t.equal(packaged.packageChecks, 1, "package.desk is reused while it is unchanged")
        packaged.setText(siblingText + "// changed\n", of: DeskFileID("Other.desk"))
        t.equal(packaged.packageChecks, 1, "a sibling's change does not check the package again")
        let withoutCard = packageText.replacingOccurrences(of: "style card { .padding(8).background(.glass) }\n", with: "")
        let afterPackage = packaged.setText(withoutCard, of: DeskFileID("package.desk"))
        t.equal(packaged.packageChecks, 2, "package.desk's change checks it again")
        let packageContext = CheckContext(package: CheckedPackage(file: Desk.check(Desk.parse(withoutCard, fileName: "package.desk"))))
        t.equal(deskServiceDescriptions(afterPackage.checked.diagnostics),
                deskServiceDescriptions(Desk.check(Desk.parse(afterPackage.text, file: widget), context: packageContext).diagnostics),
                "the widget is checked with the new package")
        t.check(afterPackage.checked.diagnostics.contains { $0.severity == .error }, "the missing style is an error")
        packaged.setText(packageText, of: DeskFileID("package.desk"))

        // The folder, only when asked, equals Desk.checkFolder.
        let snapshot = packaged.snapshot
        t.check(snapshot.caches.folder.peek() == nil, "siblings are not checked until asked")
        let folderResults = snapshot.folderResults()
        let reference = Desk.checkFolder(package: Desk.parse(packageText, fileName: "package.desk"),
                                         widgets: [Desk.parse(snapshot.text, file: widget),
                                                   Desk.parse(siblingText + "// changed\n", fileName: "Other.desk")])
        t.equal(Set(folderResults.keys), Set(reference.keys))
        for (key, result) in reference {
            t.equal(deskServiceDescriptions(folderResults[key]?.diagnostics ?? []), deskServiceDescriptions(result.diagnostics),
                    "folder result of \(key)")
        }
        t.check(folderResults[DeskFileID("package.desk")]!.diagnostics.contains { $0.id.rawValue.hasPrefix("DK") && $0.severity != .error },
                "the package's unused style is reported for the folder")

        // Editing package.desk itself.
        let packageService = DeskLanguageService(openFile: DeskFileID("package.desk"), files: folder)
        t.check(packageService.isEditingPackage)
        t.equal(deskServiceDescriptions(packageService.snapshot.checked.diagnostics),
                deskServiceDescriptions(Desk.check(Desk.parse(packageText, fileName: "package.desk")).diagnostics))
        t.equal(packageService.snapshot.packageDiagnostics, [])
        let edited = packageService.update(changes: [DeskTextChange(range: 0..<0, text: "// top\n")], version: 1)
        t.equal(edited.package?.tree.version, edited.tree.version, "the open package is the package")
        let packageFolder = edited.folderResults()
        t.equal(Set(packageFolder.keys), Set(folder.keys))

        // Another language re-words without checking again.
        let english = packaged.snapshot
        let chinese = packaged.setMessageLanguage(.simplifiedChinese)
        t.equal(chinese.tree.version, english.tree.version)
        t.equal(chinese.checked.diagnostics.count, english.checked.diagnostics.count)
        for (d, source) in zip(chinese.diagnostics, chinese.checked.diagnostics) {
            t.equal(d.message, source.message(in: .simplifiedChinese))
        }

        // Lazily built values are the same from many threads.
        let busy = DeskLanguageService(openFile: file, files: [file: base + "\nwidget { Txt(\"A\") }\n"]).snapshot
        var results = [Int](repeating: 0, count: 8)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 8) { k in
            let count = busy.diagnostics.count + busy.formatDocument().count + busy.problemCounts().count
            lock.lock()
            results[k] = count
            lock.unlock()
        }
        t.equal(Set(results).count, 1, "the same results on every thread")
    }

    t.suite("Desk: service — diagnostics") {
        // Every diagnostic fixture: the service's diagnostics are the checker's, in UTF-16.
        let fixtures = deskFixtureFiles("Diagnostics").map { DeskDiagnosticFixture.parse(path: $0.path, text: $0.text) }
        var compared = 0
        for fixture in fixtures where fixture.generate != "invalidUTF8" {
            let text = fixture.generate.map(deskGeneratedText) ?? fixture.positive
            let open = DeskFileID(fixture.fileName)
            var files = [open: text]
            if let package = fixture.package, open.path != "package.desk" { files[DeskFileID("package.desk")] = package }
            let context = deskFixtureContext(fixture, package: nil)
            let service = DeskLanguageService(openFile: open, files: files, resources: context.resources,
                                              options: DeskServiceOptions(context: context))
            let snapshot = service.snapshot
            let reference = deskCheckFixtureText(text, fixture)
            t.equal(deskServiceDescriptions(snapshot.checked.diagnostics), deskServiceDescriptions(reference.diagnostics),
                    "\(fixture.id): the checker's diagnostics")
            var trees: [DeskFileID: SyntaxTree] = [:]
            for (d, source) in zip(snapshot.diagnostics, snapshot.checked.diagnostics) {
                compared += 1
                let fileText = files[source.file] ?? ""
                if trees[source.file] == nil { trees[source.file] = Desk.parse(fileText, file: source.file) }
                t.equal(d.id, source.id)
                t.equal(d.file, source.file)
                t.equal(d.range.utf16, deskServiceUTF16(fileText, utf8: source.range), "\(fixture.id): \(d.id.rawValue) range")
                let location = trees[source.file]!.location(of: source.range.lowerBound)
                t.equal(d.line + 1, location.line, "\(fixture.id): line")
                t.equal(d.column + 1, location.utf16Column, "\(fixture.id): UTF-16 column")
                t.equal(d.message, source.message(in: .english), "\(fixture.id): message")
                t.equal(d.notes.count, source.notes.count)
                for (note, sourceNote) in zip(d.notes, source.notes) {
                    t.equal(note.message, sourceNote.message(in: .english))
                    if let noteText = files[sourceNote.file] {
                        t.equal(note.location?.range.utf16, deskServiceUTF16(noteText, utf8: sourceNote.range), "\(fixture.id): note")
                    }
                }
                t.equal(d.fixIts.count, source.fixIts.count, "\(fixture.id): fix-its")
                for (fix, sourceFix) in zip(d.fixIts, source.fixIts) {
                    // A generic title says what the fix writes when it is one line of short text.
                    if DeskSnapshot.genericFixTitles.contains(sourceFix.titleKey), fix.title != sourceFix.title(in: .english) {
                        t.check(["Change to `", "Remove `", "Insert `"].contains { fix.title.hasPrefix($0) }, "\(fixture.id): \(fix.title)")
                    } else {
                        t.equal(fix.title, sourceFix.title(in: .english))
                    }
                    t.equal(fix.group, sourceFix.group)
                    for (editedFile, original) in files {
                        let expected = TextEdit.apply(sourceFix.edits.filter { $0.file == editedFile }, to: original)
                        t.equal(deskServiceApply(fix.edit, file: editedFile, to: original), expected,
                                "\(fixture.id): fix-it \(sourceFix.titleKey) in \(editedFile)")
                    }
                }
                if let unit = source.dropped {
                    let (_, id) = DeskSnapshot.split(unit)
                    let tree = snapshot.tree(of: id)
                    t.check(tree != nil, "\(fixture.id): the dropped unit's tree")
                    if let tree, let node = tree.resolve(id) {
                        t.equal(d.dropped?.location.range.utf16, deskServiceUTF16(tree.text, utf8: node.textRange),
                                "\(fixture.id): dropped range")
                    } else {
                        t.check(false, "\(fixture.id): the dropped unit resolves")
                    }
                }
            }
            // In Chinese, without ids in any text.
            let chinese = service.setMessageLanguage(.simplifiedChinese)
            for (d, source) in zip(chinese.diagnostics, chinese.checked.diagnostics) {
                t.equal(d.message, source.message(in: .simplifiedChinese))
                for text in [d.message] + d.notes.map(\.message) + d.fixIts.map(\.title) {
                    t.check(deskMessageLeaks(text).isEmpty, "\(fixture.id): \(text)")
                }
            }
        }
        print("    \(compared) diagnostics of \(fixtures.count) fixtures compared")

        // The service's quick tree lookups agree with the tree's own, for every node of the fixtures.
        var nodes = 0
        for fixture in fixtures {
            let tree = Desk.parse(fixture.positive, fileName: "Q.desk")
            var stack = [tree.rootNode]
            while let node = stack.popLast() {
                nodes += 1
                t.equal(node.quickTextRange, node.textRange, "\(fixture.id): text range of \(node.kind)")
                let id = tree.id(of: node)
                t.equal(tree.quickResolve(id)?.range, tree.resolve(id)?.range, "\(fixture.id): resolve \(id)")
                stack.append(contentsOf: node.childNodes)
            }
        }
        t.check(nodes > 4_000, "only \(nodes) nodes")

        // UTF-16 positions after CJK and an emoji; the dropped element's range for the ghost.
        let file = DeskFileID("Ghost.desk")
        let ghostText = "// 中文 😀\ninfo { name: \"G\" }\nwidget {\n    Column {\n        Txt(\"A\")\n        Text(\"B\")\n    }\n}\n"
        let ghost = DeskLanguageService(openFile: file, files: [file: ghostText]).snapshot
        let dropped = ghost.diagnostics.compactMap(\.dropped).first
        t.equal(dropped?.kind, .element)
        if let dropped {
            t.equal((ghostText as NSString).substring(with: dropped.location.range.nsRange), "Txt(\"A\")")
            t.equal(dropped.location.range.start.line, 4)
            t.equal(dropped.location.range.start.column, 8)
        }

        // Problem counts per file: tips are not problems; a package problem is counted once.
        let counted = DeskLanguageService(openFile: DeskFileID("W.desk"), files: [
            DeskFileID("W.desk"): "info { name: \"W\" }\nwidget {\n    Txt(\"A\")\n    Text(\"B\").style(\"card\")\n}\n",
            DeskFileID("package.desk"): "package { name: \"P\" }\nstyle card { .padding(4) }\nstyle card { .padding(2) }\n",
        ]).snapshot
        let counts = counted.problemCounts()
        let widgetErrors = counted.checked.diagnostics.filter { $0.file.path == "W.desk" && $0.severity == .error }.count
        let widgetWarnings = counted.checked.diagnostics.filter { $0.file.path == "W.desk" && $0.severity == .warning }.count
        t.equal(counts[DeskFileID("W.desk")]?.errors, widgetErrors)
        t.equal(counts[DeskFileID("W.desk")]?.warnings, widgetWarnings)
        t.check(widgetErrors >= 1, "the misspelt component is an error")
        t.check((counts[DeskFileID("package.desk")]?.problems ?? 0) >= 1, "the package's duplicate style is counted")
        let packageOwn = Set(counted.packageDiagnostics.map { "\($0.id.rawValue)@\($0.range)" })
        t.equal(packageOwn.count, counted.packageDiagnostics.count)
        t.equal(counts[DeskFileID("package.desk")]?.problems,
                counted.packageDiagnostics.filter(\.isProblem).count
                    + counted.diagnostics.filter { $0.file.path == "package.desk" && $0.isProblem
                        && !packageOwn.contains("\($0.id.rawValue)@\($0.range)") }.count)
        let tip = DeskLanguageService(openFile: file, files: [file: "info { name: \"T\" }\nwidget { Text(\"A\").bold() }\n"]).snapshot
        for d in tip.diagnostics where d.severity == .info { t.check(!d.isProblem) }
        t.equal(tip.problemCounts()[file]?.problems, tip.diagnostics.filter(\.isProblem).count)
        t.equal(counted.folderProblemCounts()[DeskFileID("W.desk")], counts[DeskFileID("W.desk")])

        // "Fix all": every fix-it of a group in one edit.
        let quoted = "info { name: \"Q\" }\nstyle a { .padding(2) }\nstyle b { .padding(4) }\n"
            + "widget {\n    Text(\"A\").style(\"a\")\n    Text(\"B\").style(\"b\")\n}\n"
        let quotedSnapshot = DeskLanguageService(openFile: file, files: [file: quoted]).snapshot
        let groups = Set(quotedSnapshot.diagnostics.flatMap { $0.fixIts.compactMap(\.group) })
        t.check(groups.contains("quotedOwnName"), "a grouped fix-it: \(groups)")
        let fixAll = quotedSnapshot.fixAll(group: "quotedOwnName")
        let fixed = deskServiceApply(fixAll, file: file, to: quoted)
        t.check(fixed.contains(".style(a)") && fixed.contains(".style(b)"), "both fixed: \(fixed)")
    }

    t.suite("Desk: service — formatting") {
        var texts = deskFixtureFiles("Format").map(\.text) + deskFixtureFiles("Acceptance").map(\.text)
        texts.append("// 中文 😀\r\ninfo { name: \"寬\" }\r\nwidget {\r\n  Row{ Text(\"日本\")   ;Text(\"😀\") }\r\n        Text(\"x\")\r\n}\r\n")
        texts.append("\u{FEFF}widget {\n\tText(\"A\")\n  .font(.caption)\n}\n")
        var random = DeskRandom(seed: 0xF0_2026)
        for (k, text) in texts.enumerated() {
            let file = DeskFileID("F\(k).desk")
            let snapshot = DeskLanguageService(openFile: file, files: [file: text]).snapshot
            let whole = snapshot.formatDocument()
            let formatted = Desk.formatted(snapshot.tree)
            t.equal(DeskTextEditU16.apply(whole, to: text), formatted, "formatDocument of text \(k)")
            t.equal(DeskWorkspaceEdit([file: whole]).edits(for: file), whole, "sorted and not overlapping")
            t.equal(snapshot.formatRange(snapshot.index.range(utf16: 0..<snapshot.index.utf16Count)), whole,
                    "the whole text as a range")
            for _ in 0..<12 {
                let a = deskServiceScalarStart(text as NSString, random.int(snapshot.index.utf16Count + 1))
                let b = deskServiceScalarStart(text as NSString, random.int(snapshot.index.utf16Count + 1))
                let range = snapshot.index.range(utf16: min(a, b)..<max(a, b))
                let edits = snapshot.formatRange(range)
                let widened = snapshot.formattingRange(for: range)
                t.check(widened.start.offset <= range.start.offset && widened.start.column == 0, "widened to a line start")
                t.equal(widened.end.offset, snapshot.index.utf16ContentRange(ofLine: widened.end.line).upperBound,
                        "widened to a line end")
                t.check(Set(edits).isSubset(of: Set(whole)), "a subset of the document's edits")
                for edit in edits { t.check(edit.range.meets(widened), "\(edit) meets \(widened)") }
                // Formatting the rest afterwards gives the same file.
                let partly = DeskTextEditU16.apply(edits, to: text)
                t.equal(Desk.formatted(Desk.parse(partly, file: file)), formatted, "text \(k), range \(range)")
            }
        }
        // Only the selected statement's line.
        let text = "widget {\n      Text(\"A\")\n  Text(\"B\")   .font(.caption)\n}\n"
        let file = DeskFileID("Sel.desk")
        let snapshot = DeskLanguageService(openFile: file, files: [file: text]).snapshot
        let second = (text as NSString).range(of: "Text(\"B\")")
        let edits = snapshot.formatRange(NSRange(location: second.location + 2, length: 1))
        t.equal(DeskTextEditU16.apply(edits, to: text), "widget {\n      Text(\"A\")\n    Text(\"B\").font(.caption)\n}\n")
        let lineSelection = (text as NSString).lineRange(for: second)
        t.equal(DeskTextEditU16.apply(snapshot.formatRange(lineSelection), to: text),
                "widget {\n      Text(\"A\")\n    Text(\"B\").font(.caption)\n}\n", "a selection that ends at the next line's start")
        t.equal(snapshot.formatRange(NSRange(location: NSNotFound, length: 0)), [])
    }

    t.suite("Desk: service latency") {
        // Typing in the code pane: p50 and p95 over random one-character edits of the large test widget, for the
        // update with its diagnostics and semantic tokens (target under 20 ms at 300 lines in a release build), and
        // for completion, hover and signature help (under 5 ms each), the outline and folding on the new snapshot.
        // DESK_SERVICE_LATENCY_BUDGET_MS=20 asserts those targets (the requests get a quarter of the budget);
        // without it only a generous bound is checked: 10x in debug, 3x more for a slow CI machine.
        #if DEBUG
        let build = "debug"
        let factor = 10.0
        #else
        let build = "release"
        let factor = 1.0
        #endif
        let strict = ProcessInfo.processInfo.environment["DESK_SERVICE_LATENCY_BUDGET_MS"].flatMap(Double.init)
        func milliseconds(_ body: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            return (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded(.up)))]
        }
        func figures(_ values: [Double]) -> String {
            String(format: "p50 %.2f, p95 %.2f", percentile(values, 0.5), percentile(values, 0.95))
        }
        let typed = ["a", "e", "x", "1", " ", ".", "(", "\"", "{", "}", "\n"]
        if ProcessInfo.processInfo.environment["DESK_SERVICE_PROFILE"] != nil {
            // Where an update's time goes (best of five).
            for lines in [300, 2_000] {
                func best(_ body: () -> Void) -> Double { (0..<5).map { _ in milliseconds(body) }.min()! }
                let text = deskLargeWidget(lines: lines)
                let file = DeskFileID("Large.desk")
                let previous = Desk.parse(text, file: file)
                let at = (text as NSString).range(of: "CPU 1\"").location
                let edited = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "x")
                var fresh: SyntaxTree!
                let parse = best { fresh = Desk.parse(edited, file: file) }
                let old = Array(text.utf8), new = Array(edited.utf8)
                var shared: SyntaxTree!
                let share = best { shared = SubtreeReuse.share(fresh, previous: previous, edit: SyntaxTextEdit.between(old, new), newBytes: new, oldBytes: old).tree }
                let textIndex = best { _ = DeskTextIndex(tree: shared) }
                let check = best { _ = Desk.check(shared) }
                let service = DeskLanguageService(openFile: file, files: [file: edited])
                let table = best { _ = DeskNodeTable(tree: shared) }
                let index = best { _ = service.setMessageLanguage(.english).symbolIndex }
                let tokens = best { _ = service.setMessageLanguage(.english).semanticTokens() }
                let pending = service.beginUpdate(changes: [], version: 1)
                let syntaxIndex = best { _ = DeskSymbolIndex(checked: pending.snapshot.checked, packageFile: nil, packageStyles: [], packageOptions: [], catalog: .current) }
                let diagnostics = best { _ = service.setMessageLanguage(.english).diagnostics }
                print(String(format: "    %d lines: parse %.2f, share %.2f, text index %.2f, check %.2f, node table %.2f, symbol index %.2f "
                             + "(syntax only %.2f), semantic tokens with index %.2f, diagnostics %.2f ms",
                             lines, parse, share, textIndex, check, table, index, syntaxIndex, tokens, diagnostics))
            }
        }
        for lines in [300, 2_000] {
            let text = deskLargeWidget(lines: lines)
            let file = DeskFileID("Large.desk")
            let service = DeskLanguageService(openFile: file, files: [file: text])
            func warm(_ snapshot: DeskSnapshot) {
                _ = snapshot.diagnostics
                _ = snapshot.semanticTokens()
                _ = snapshot.documentSymbols()
                _ = snapshot.foldingRanges()
            }
            warm(service.snapshot)
            var random = DeskRandom(seed: 0x1A7E_2026 &+ UInt64(lines))
            var update: [Double] = [], completion: [Double] = [], hover: [Double] = [], signature: [Double] = []
            var outline: [Double] = [], folding: [Double] = [], phased: [Double] = [], check: [Double] = []
            var version = 0
            #if DEBUG
            let edits = lines == 300 ? 50 : 8
            #else
            let edits = 50
            #endif
            let reuseBefore = service.totalReuse
            for k in 0..<edits {
                // One character typed or deleted at a random place (the widget is ASCII but for "·").
                let current = service.text as NSString
                let at = random.int(current.length)
                let insert = random.chance(75)
                let change = insert ? DeskTextChange(range: at..<at, text: random.pick(typed))
                                    : DeskTextChange(range: at..<(at + 1), text: "")
                let undo = insert ? DeskTextChange(range: at..<(at + (change.text as NSString).length), text: "")
                                  : DeskTextChange(range: at..<at, text: current.substring(with: NSRange(location: at, length: 1)))
                version += 1
                var snapshot: DeskSnapshot!
                update.append(milliseconds {
                    snapshot = service.update(changes: [change], version: version)
                    _ = snapshot.diagnostics
                    _ = snapshot.semanticTokens()
                })
                outline.append(milliseconds { _ = snapshot.documentSymbols() })
                folding.append(milliseconds { _ = snapshot.foldingRanges() })
                // Requests near a random line: a modifier after `.`, a name, the arguments of a call.
                let ns = snapshot.text as NSString
                let from = ns.lineRange(for: NSRange(location: random.int(ns.length), length: 0)).location
                func find(_ needle: String) -> Int? {
                    var r = ns.range(of: needle, range: NSRange(location: from, length: ns.length - from))
                    if r.location == NSNotFound { r = ns.range(of: needle) }
                    return r.location == NSNotFound ? nil : r.location
                }
                if let dot = find(".font(") {
                    let position = snapshot.index.position(utf16: dot + 1)
                    completion.append(milliseconds { _ = snapshot.completions(at: position) })
                }
                if let name = find("page") {
                    let position = snapshot.index.position(utf16: name + 2)
                    hover.append(milliseconds { _ = snapshot.hover(at: position) })
                }
                if let call = find("Text(\"") {
                    let position = snapshot.index.position(utf16: call + 5)
                    signature.append(milliseconds { _ = snapshot.signatureHelp(at: position) })
                }
                // Back to the widget as it was, with what the Studio asks of each snapshot.
                version += 1
                warm(service.update(changes: [undo], version: version))
                // Two phases, as for a large file: the syntax snapshot with folding and highlighting, then the check.
                if k % 5 == 0 {
                    version += 1
                    var pending: DeskPendingCheck!
                    phased.append(milliseconds {
                        pending = service.beginUpdate(changes: [change], version: version)
                        _ = pending.snapshot.foldingRanges()
                        _ = pending.snapshot.semanticTokens()
                    })
                    var result: DeskCheckedText!
                    check.append(milliseconds { result = pending.run() })
                    warm(service.accept(result)!)
                    version += 1
                    warm(service.update(changes: [undo], version: version))
                }
            }
            t.equal(service.text, text, "the edits were undone")
            var reuse = service.totalReuse
            reuse.nodes -= reuseBefore.nodes
            reuse.sharedNodes -= reuseBefore.sharedNodes
            let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
            print("    Desk service, \(build) build, \(count) lines, \(edits) one-character edits (ms):")
            print("      update + diagnostics + semantic tokens \(figures(update)); completion \(figures(completion)); "
                  + "hover \(figures(hover)); signature help \(figures(signature))")
            print("      outline \(figures(outline)); folding \(figures(folding)); "
                  + "in two phases: syntax snapshot \(figures(phased)), then the check \(figures(check)); "
                  + String(format: "%.0f%% of nodes shared", reuse.nodeRate * 100))
            let p95 = percentile(update, 0.95)
            let requests = [completion, hover, signature].map { percentile($0, 0.95) }.max() ?? 0
            if let budget = strict, lines == 300 {
                t.check(p95 < budget, String(format: "p95 of a one-character update of 300 lines is %.1f ms (budget %.0f)", p95, budget))
                t.check(requests < budget / 4, String(format: "p95 of a request is %.2f ms (budget %.1f)", requests, budget / 4))
            }
            // Only a bound that keeps the editor usable (CI machines are slow and stall).
            let bound = (lines == 300 ? 20.0 : 200.0) * factor * 3
            t.check(p95 < bound, String(format: "p95 of a one-character update of %d lines is %.0f ms (bound %.0f)", lines, p95, bound))
            t.check(requests < 5 * factor * 3 * (lines == 300 ? 1 : 4),
                    String(format: "p95 of a request of %d lines is %.1f ms", lines, requests))
        }
        // Wording and formatting from a snapshot with empty caches.
        let text = deskLargeWidget(lines: 2_000)
        let file = DeskFileID("Large.desk")
        let faulty = DeskLanguageService(openFile: file, files: [file: text.replacingOccurrences(of: "Text(\"CPU", with: "Txt(\"CPU")])
        let wording = milliseconds { _ = faulty.setMessageLanguage(.english).diagnostics }
        let format = milliseconds { _ = faulty.setMessageLanguage(.english).formatDocument() }
        print(String(format: "    wording %d diagnostics %.1f ms; formatting 2,000 lines %.1f ms",
                     faulty.snapshot.checked.diagnostics.count, wording, format))
    }
}
