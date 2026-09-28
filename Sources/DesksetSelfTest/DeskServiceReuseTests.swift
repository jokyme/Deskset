import Foundation
@testable import DeskLanguage

// Reuse between parses and snapshots: trees built with shared subtrees print and compare exactly like Desk.parse;
// after random edit sequences, a service's snapshots (which reuse the highlighting, folding and outline of unchanged
// top-level blocks) equal freshly opened ones; checks in the background publish only the latest.

/// Texts with several top-level blocks, so most edits leave some block untouched.
private func deskReuseBases() -> [String] {
    var bases: [String] = []
    for name in ["Acceptance/MonthView.desk", "Acceptance/CPU.desk", "Packages/Harbor/Lamp.desk", "Packages/Harbor/Radio.desk",
                 "Packages/Harbor/Tide.desk", "Packages/Harbor/package.desk"] {
        if let text = deskFixtureFiles().first(where: { $0.path == name })?.text { bases.append(text) }
    }
    for file in deskFixtureFiles("Format") where file.path.hasSuffix(".formatted.desk") { bases.append(file.text) }
    bases.append(deskLargeWidget(lines: 80) + "\nstyle extra { .bold() }\n\ntranslations {\n    \"zh-Hans\" {\n        \"Large\": \"大\"\n    }\n}\n")
    return bases
}

/// Pieces random edits insert.
private let deskReusePieces = ["x", "a", " ", "\n", "\r\n", "}", "{", "(", ")", "\"", ".", ",", "Text(\"A\")", ".font(.caption)",
                               "// note\n", "中", "😀", "style s { .bold() }\n", "", "", "variable n = 1\n", "Row { Text(\"B\") }",
                               "info { name: \"X\" }\n", "\t", "é"]

/// A UTF-16 offset moved off the second half of a surrogate pair.
private func deskReuseScalarStart(_ s: NSString, _ offset: Int) -> Int {
    guard offset > 0, offset < s.length else { return max(0, min(offset, s.length)) }
    let c = s.character(at: offset)
    let before = s.character(at: offset - 1)
    return (0xDC00...0xDFFF).contains(c) && (0xD800...0xDBFF).contains(before) ? offset - 1 : offset
}

/// One to three random changes, applied to `text` as they are made (each range in the text the ones before left).
private func deskReuseChanges(_ random: inout DeskRandom, _ text: NSMutableString) -> [DeskTextChange] {
    var changes: [DeskTextChange] = []
    for _ in 0..<(1 + (random.chance(15) ? random.int(3) : 0)) {
        let lower = deskReuseScalarStart(text, random.int(text.length + 1))
        let upper = deskReuseScalarStart(text, min(text.length, lower + (random.chance(50) ? 0 : random.int(10))))
        let range = NSRange(location: lower, length: max(0, upper - lower))
        let insert = random.pick(deskReusePieces)
        text.replaceCharacters(in: range, with: insert)
        changes.append(DeskTextChange(nsRange: range, text: insert))
    }
    return changes
}

/// An outline without the tree versions of its element references.
private func deskReuseOutline(_ symbols: [DeskDocumentSymbol]) -> [String] {
    var out: [String] = []
    func visit(_ s: DeskDocumentSymbol, _ depth: Int) {
        out.append("\(depth) \(s.kind.rawValue) \(s.name) \(s.detail ?? "-") \(s.range.utf16) \(s.selectionRange.utf16) "
                   + "\(s.element.map { "\($0.kind.rawValue)@\($0.utf8Start)" } ?? "-")")
        for child in s.children { visit(child, depth + 1) }
    }
    for s in symbols { visit(s, 0) }
    return out
}

func runDeskServiceReuseTests(_ t: TestRunner) {
    t.suite("Desk: service — subtree reuse") {
        var random = DeskRandom(seed: 0x5AB7_2026)
        var total = SubtreeReuseStats()
        var trees = 0
        let texts = deskReuseBases() + deskFixtureFiles("Diagnostics").enumerated().filter { $0.offset % 4 == 0 }.map(\.element.text)
        for base in texts {
            var previous = Desk.parse(base, fileName: "R.desk")
            let text = NSMutableString(string: base)
            for _ in 0..<12 {
                _ = deskReuseChanges(&random, text)
                let new = text as String
                let (shared, stats) = Desk.reparse(new, previous: previous)
                let fresh = Desk.parse(new, fileName: "R.desk")
                trees += 1
                t.check(SubtreeReuse.identical(shared, fresh), "shared tree differs from Desk.parse: \(new.debugDescription)")
                t.equal(shared.description, new, "the shared tree prints its text")
                t.equal(shared.root.outline, fresh.root.outline)
                t.equal(shared.diagnostics, fresh.diagnostics)
                t.equal(shared.header, fresh.header)
                t.equal(stats.nodes, SubtreeReuse.countNodes(fresh.root), "nodes counted")
                total.add(stats)
                previous = shared
            }
        }
        print("    \(trees) trees after random edits: \(total)")
        t.check(total.nodeRate > 0.5, "only \(total) shared")

        // An edit inside the widget keeps every other top-level block, and the unchanged parts of the widget.
        let month = deskReuseBases()[0]
        let before = Desk.parse(month, fileName: "M.desk")
        let at = (month as NSString).range(of: "widget {").location + 9
        let edited = (month as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "\n    variable z = 1")
        let (after, stats) = Desk.reparse(edited, previous: before)
        let oldBlocks = before.root.childNodes, newBlocks = after.root.childNodes
        t.equal(oldBlocks.count, newBlocks.count)
        for (old, new) in zip(oldBlocks, newBlocks) {
            t.equal(old === new, new.kind != .widgetBlock, "\(new.kind) kept: \(old === new)")
        }
        t.check(stats.sharedSubtrees > oldBlocks.count, "statements of the widget are shared too: \(stats)")
        // Unchanged text: the whole tree is the previous one, with the new parse's version.
        let (same, sameStats) = Desk.reparse(month, previous: before)
        t.check(same.root === before.root && same.version != before.version, "the same text keeps the root")
        t.equal(sameStats.nodeRate, 1.0)
        // A deep tree (a long else-if chain) is walked without recursion.
        var deep = "widget {\n    variable n = 0\n    if n == 0 { Text(\"0\") }"
        for k in 1..<400 { deep += " else if n == \(k) { Text(\"\(k)\") }" }
        deep += "\n}\n"
        let deepTree = Desk.parse(deep, fileName: "D.desk")
        let deepEdited = deep.replacingOccurrences(of: "n == 399", with: "n == 398")
        let (deepShared, deepStats) = Desk.reparse(deepEdited, previous: deepTree)
        t.check(SubtreeReuse.identical(deepShared, Desk.parse(deepEdited, fileName: "D.desk")), "deep tree")
        t.check(deepStats.sharedNodes > 0, "\(deepStats)")
        // The edit between two texts.
        t.equal(SyntaxTextEdit.between(Array("abcdef".utf8), Array("abXYef".utf8)), SyntaxTextEdit(start: 2, oldEnd: 4, newEnd: 4))
        t.equal(SyntaxTextEdit.between(Array("aaaa".utf8), Array("aaa".utf8)), SyntaxTextEdit(start: 3, oldEnd: 4, newEnd: 3))
        t.equal(SyntaxTextEdit.between(Array("abc".utf8), Array("abc".utf8)), SyntaxTextEdit(start: 3, oldEnd: 3, newEnd: 3))
        t.equal(SyntaxTextEdit.between(Array("".utf8), Array("xyz".utf8)), SyntaxTextEdit(start: 0, oldEnd: 0, newEnd: 3))
        t.equal(SyntaxTextEdit.between(Array("0123456789abcdefg".utf8), Array("0123456789abcdefX".utf8)),
                SyntaxTextEdit(start: 16, oldEnd: 17, newEnd: 17))
    }

    t.suite("Desk: service — reuse differential") {
        var random = DeskRandom(seed: 0xD1FF_2026)
        let bases = deskReuseBases()
        let file = DeskFileID("Reuse.desk")
        var counts = DeskBlockMemo.Counts()
        var compared = 0
        var steps = 0
        var service: DeskLanguageService!
        func add(_ c: DeskBlockMemo.Counts) {
            counts.semanticReused += c.semanticReused
            counts.semanticBuilt += c.semanticBuilt
            counts.foldingReused += c.foldingReused
            counts.foldingBuilt += c.foldingBuilt
            counts.outlineReused += c.outlineReused
            counts.outlineBuilt += c.outlineBuilt
        }
        var subtrees = SubtreeReuseStats()
        for sequence in 0..<300 {
            let base = bases[sequence % bases.count]
            service = DeskLanguageService(openFile: file, files: [file: base])
            var language = DiagnosticLanguage.english
            let text = NSMutableString(string: base)
            let length = 1 + random.int(6)
            for step in 0..<length {
                let changes = deskReuseChanges(&random, text)
                steps += 1
                var snapshot: DeskSnapshot
                if random.chance(15) {
                    // In two phases: the syntax snapshot first, then the check.
                    let pending = service.beginUpdate(changes: changes, version: steps)
                    t.check(!pending.snapshot.isChecked, "a syntax snapshot first")
                    _ = pending.snapshot.foldingRanges()
                    _ = pending.snapshot.semanticTokens()
                    snapshot = service.accept(pending.run()) ?? service.snapshot
                } else {
                    snapshot = service.update(changes: changes, version: steps)
                }
                if random.chance(10) {
                    language = language == .english ? .simplifiedChinese : .english
                    snapshot = service.setMessageLanguage(language)
                }
                // What the Studio asks of every snapshot, so the next one can reuse it.
                let tokens = snapshot.semanticTokens()
                let outline = snapshot.documentSymbols()
                let folding = snapshot.foldingRanges()
                let diagnostics = snapshot.diagnostics
                add(snapshot.memo.reuseCounts)
                t.check(snapshot.isChecked, "the published snapshot is checked")
                t.check(SubtreeReuse.identical(snapshot.tree, Desk.parse(text as String, file: file)),
                        "sequence \(sequence) step \(step): tree")
                if step == length - 1 || random.chance(30) {
                    compared += 1
                    let fresh = DeskLanguageService(openFile: file, files: [file: text as String],
                                                    options: DeskServiceOptions(messageLanguage: language)).snapshot
                    let where_ = "sequence \(sequence) step \(step)"
                    t.equal(snapshot.text, text as String, "\(where_): text")
                    t.equal(diagnostics, fresh.diagnostics, "\(where_): diagnostics")
                    t.equal(tokens.tokens, fresh.semanticTokens().tokens, "\(where_): semantic tokens")
                    t.equal(tokens.data, fresh.semanticTokens().data, "\(where_): encoded tokens")
                    t.equal(deskReuseOutline(outline), deskReuseOutline(fresh.documentSymbols()), "\(where_): outline")
                    t.equal(folding, fresh.foldingRanges(), "\(where_): folding")
                }
            }
            subtrees.add(service.totalReuse)
        }
        func rate(_ reused: Int, _ built: Int) -> String {
            String(format: "%d of %d (%.0f%%)", reused, reused + built, reused + built == 0 ? 0 : 100.0 * Double(reused) / Double(reused + built))
        }
        print("    300 sequences, \(steps) edits, \(compared) comparisons with fresh snapshots")
        print("    subtrees: \(subtrees)")
        print("    blocks reused: semantic runs \(rate(counts.semanticReused, counts.semanticBuilt)), "
              + "folding \(rate(counts.foldingReused, counts.foldingBuilt)), outline \(rate(counts.outlineReused, counts.outlineBuilt))")
        t.check(counts.semanticReused > 0 && counts.foldingReused > 0 && counts.outlineReused > 0, "every kind of block result was reused")
        t.check(compared >= 300, "only \(compared) comparisons")
    }

    t.suite("Desk: service — background checking") {
        let file = DeskFileID("Bg.desk")
        let text = deskLargeWidget(lines: 60)
        var options = DeskServiceOptions()
        options.backgroundCheckBytes = 1
        let service = DeskLanguageService(openFile: file, files: [file: text], options: options)
        let at = (text as NSString).range(of: "CPU 1\"").location
        let broken = DeskTextChange(range: at..<at, text: "Txt(\"x\") ")

        // Two phases: syntax results at once, the check later.
        let pending = service.beginUpdate(changes: [broken], version: 1)
        let syntax = service.snapshot
        t.check(!syntax.isChecked && syntax === pending.snapshot, "the syntax snapshot is published")
        t.equal(syntax.checked.diagnostics, syntax.tree.diagnostics, "only the tree's diagnostics")
        let fresh = DeskLanguageService(openFile: file, files: [file: syntax.text]).snapshot
        t.equal(syntax.foldingRanges(), fresh.foldingRanges(), "folding needs no check")
        t.check(!syntax.semanticTokens().isEmpty, "highlighting from the tree alone")
        var result: DeskCheckedText?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result = pending.run()
            done.signal()
        }
        t.check(done.wait(timeout: .now() + 120) == .success, "the check finished")
        let checked = service.accept(result!)
        t.check(checked?.isChecked == true, "the check is published")
        t.equal(checked?.diagnostics, fresh.diagnostics)
        t.equal(checked?.version, 1)
        t.check(checked!.generation > syntax.generation)

        // A later change drops an earlier check.
        let first = service.beginUpdate(changes: [DeskTextChange(range: 0..<0, text: " ")], version: 2)
        let second = service.beginUpdate(changes: [DeskTextChange(range: 0..<1, text: "")], version: 3)
        t.check(service.accept(first.run()) == nil, "a stale check is dropped")
        t.equal(service.accept(second.run())?.version, 3)
        // So do a change of package.desk and new options; a new message language does not.
        let third = service.beginUpdate(changes: [DeskTextChange(range: 0..<0, text: "\n")], version: 4)
        service.setText("package { name: \"P\" }\n", of: DeskFileID("package.desk"))
        t.check(service.accept(third.run()) == nil, "stale after package.desk changed")
        let fourth = service.beginUpdate(changes: [DeskTextChange(range: 0..<1, text: "")], version: 5)
        service.setMessageLanguage(.simplifiedChinese)
        let worded = service.accept(fourth.run())
        t.equal(worded?.version, 5)
        t.equal(worded?.options.messageLanguage, .simplifiedChinese, "the language set while checking")
        let fifth = service.beginUpdate(changes: [DeskTextChange(range: 0..<0, text: " ")], version: 6)
        service.setOptions(options)
        t.check(service.accept(fifth.run()) == nil, "stale after new options")
        // run() checks once.
        t.check(fifth.run().checked.diagnostics == fifth.run().checked.diagnostics, "the same result twice")

        // On queues: two quick updates deliver only the latest check.
        let owner = DispatchQueue(label: "desk.test.owner")
        let checking = DispatchQueue(label: "desk.test.check")
        let lock = NSLock()
        var delivered: [Int] = []
        let delivery = DispatchSemaphore(value: 0)
        var returned: [DeskSnapshot] = []
        owner.sync {
            for version in [7, 8] {
                returned.append(service.update(changes: [DeskTextChange(range: 0..<0, text: "x")], version: version,
                                               checkingOn: checking, deliverOn: owner) { snapshot in
                    lock.lock()
                    delivered.append(snapshot.version)
                    lock.unlock()
                    delivery.signal()
                })
            }
        }
        t.check(returned.allSatisfy { !$0.isChecked }, "large texts return the syntax snapshot")
        t.check(delivery.wait(timeout: .now() + 120) == .success, "the check was delivered")
        checking.sync {}
        owner.sync {}
        lock.lock()
        t.equal(delivered, [8], "only the latest check is delivered")
        lock.unlock()
        owner.sync {
            t.equal(service.snapshot.version, 8)
            t.check(service.snapshot.isChecked)
        }
        // A small text is checked at once and nothing is delivered.
        var small = DeskServiceOptions()
        small.backgroundCheckBytes = 1 << 30
        let quick = DeskLanguageService(openFile: file, files: [file: "widget { Text(\"A\") }\n"], options: small)
        var calls = 0
        let now = quick.update(changes: [DeskTextChange(range: 0..<0, text: " ")], version: 1, checkingOn: checking,
                               deliverOn: owner) { _ in calls += 1 }
        checking.sync {}
        owner.sync {}
        t.check(now.isChecked && calls == 0, "checked at once")
    }
}
