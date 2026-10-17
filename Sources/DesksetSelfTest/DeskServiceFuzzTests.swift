import Foundation
@testable import DeskLanguage

// The language service under hostile input: every request (update, diagnostics, completion, hover, signature help,
// definition, references, highlights, prepareRename, rename, symbols, folding, semantic tokens, code actions,
// formatting of the file and of a range) asked at every offset of the acceptance widgets, the diagnostic fixtures,
// sampled corpus snippets and hostile texts: 10,000 unclosed braces, deep nesting, a 32k text, CR and CR LF, a byte
// order mark, emoji, bidirectional marks and full-width punctuation. Nothing may crash, every position must be inside
// its file, at a scalar's start, with the line and column NSString gives its offset, and two services opened on the
// same folder must answer the same. Texts longer than a case's budget are asked at evenly spaced offsets and at their
// tokens' ends; updates insert a hostile piece at every offset (or evenly spaced ones) and take it out again.
//
// `DESK_FUZZ_ONLY=<label part>` runs only the cases whose label contains it; `DESK_FUZZ_VERBOSE=1` prints each case
// with its offsets and time; `DESK_FUZZ_PROFILE=1` adds the time each request took.

/// A folder the fuzz opens, and how densely it is asked.
struct DeskFuzzCase {
    var label: String
    var file: String
    var files: [String: String]
    /// A loaded folder (its pictures and fonts as resources); `files` then holds its `.desk` texts.
    var package: DeskPackage?
    /// A text of up to this many UTF-16 offsets is asked at every offset; a longer one at evenly spaced offsets and
    /// at its tokens' ends, this many in all.
    var maxOffsets = 4_000
    /// At most this many insertions (each taken out again) are made, evenly spaced; every `checkEvery`-th is checked.
    var maxUpdates = 160
    var checkEvery = 8
    /// How many replacements of hostile ranges (split surrogate pairs, past the end…) are made, each checked.
    var replacements = 12
    /// How many offsets are asked twice of one snapshot.
    var askedAgain = 64
    /// How many renames are made (one per rename place).
    var renames = 24

    init(_ label: String, file: String = "Test.desk", files: [String: String]) {
        self.label = label
        self.file = file
        self.files = files
    }

    init(_ label: String, file: String = "Test.desk", text: String) {
        self.init(label, file: file, files: [file: text])
    }

    func service() -> DeskLanguageService {
        if let package { return DeskLanguageService(package: package, openFile: DeskFileID(path: file)) }
        var ids: [DeskFileID: String] = [:]
        for (path, text) in files { ids[DeskFileID(path: path)] = text }
        return DeskLanguageService(openFile: DeskFileID(path: file), files: ids, resources: DeskFakeResources())
    }
}

/// The line and UTF-16 column of every UTF-16 offset of a text (0…length), worked out from NSString, and whether a
/// scalar starts there: LF, CR LF and a lone CR break lines; the offset between a CR and its LF is on the CR's line.
struct DeskFuzzLines {
    let lines: [Int]
    let columns: [Int]
    let scalarStarts: [Bool]

    init(_ text: String) {
        let s = text as NSString
        let n = s.length
        var lines = [Int](repeating: 0, count: n + 1)
        var columns = [Int](repeating: 0, count: n + 1)
        var starts = [Bool](repeating: true, count: n + 1)
        var line = 0
        var start = 0
        var i = 0
        while i <= n {
            lines[i] = line
            columns[i] = i - start
            guard i < n else { break }
            let c = s.character(at: i)
            if UTF16.isTrailSurrogate(c), i > 0, UTF16.isLeadSurrogate(s.character(at: i - 1)) { starts[i] = false }
            if c == 0x0A || (c == 0x0D && !(i + 1 < n && s.character(at: i + 1) == 0x0A)) {
                line += 1
                start = i + 1
            } else if c == 0x0D {
                lines[i + 1] = line
                columns[i + 1] = i + 1 - start
                line += 1
                start = i + 2
                i += 1
            }
            i += 1
        }
        self.lines = lines
        self.columns = columns
        scalarStarts = starts
    }
}

/// Collects what is wrong with the results of one snapshot.
struct DeskFuzzProbe {
    let snapshot: DeskSnapshot
    var problems: [String] = []

    init(_ snapshot: DeskSnapshot) { self.snapshot = snapshot }

    /// The reference lines of the folder's texts, made on first use.
    var tables: [DeskFileID: DeskFuzzLines] = [:]

    /// A position must be inside its file, at the start of a scalar, with the line and column of its offset.
    mutating func position(_ p: DeskPosition, file: DeskFileID, _ what: @autoclosure () -> String) {
        guard let text = file == snapshot.file ? snapshot.text : snapshot.folder[file] else {
            // A file the folder has no text for (a picture): only its start.
            if p != DeskPosition(offset: 0, line: 0, column: 0) { problems.append("\(what()): \(p.offset) in \(file.path), not a text") }
            return
        }
        let table: DeskFuzzLines
        if let known = tables[file] {
            table = known
        } else {
            table = DeskFuzzLines(text)
            tables[file] = table
        }
        guard p.offset >= 0, p.offset < table.lines.count else {
            problems.append("\(what()): offset \(p.offset) outside \(file.path) (\(table.lines.count - 1) units)")
            return
        }
        if !table.scalarStarts[p.offset] { problems.append("\(what()): \(p.offset) splits a surrogate pair") }
        if table.lines[p.offset] != p.line || table.columns[p.offset] != p.column {
            problems.append("\(what()): \(p.offset) at \(p.line):\(p.column), expected \(table.lines[p.offset]):\(table.columns[p.offset])")
        }
    }

    mutating func range(_ r: DeskRange, file: DeskFileID? = nil, _ what: @autoclosure () -> String) {
        let file = file ?? snapshot.file
        position(r.start, file: file, "\(what()) start")
        position(r.end, file: file, "\(what()) end")
        if r.start.offset > r.end.offset { problems.append("\(what()): reversed \(r)") }
    }

    mutating func location(_ l: DeskLocation, _ what: @autoclosure () -> String) {
        range(l.range, file: l.file, what())
    }

    /// Every edit inside its file; applying them never fails.
    mutating func edit(_ e: DeskWorkspaceEdit, _ what: @autoclosure () -> String) {
        for file in e.changedFiles {
            let edits = e.edits(for: file)
            var reached = 0
            for edit in edits {
                range(edit.range, file: file, "\(what()) edit")
                if edit.range.start.offset < reached { problems.append("\(what()): overlapping edits in \(file.path)") }
                reached = max(reached, edit.range.end.offset)
            }
            // Applying copies the text: done for the first edits of each probe only.
            if applied < 64 {
                applied += 1
                _ = DeskTextEditU16.apply(edits, to: snapshot.folder[file] ?? "")
            }
        }
    }

    /// How many edits were applied.
    var applied = 0

    mutating func edits(_ edits: [DeskTextEditU16], _ what: @autoclosure () -> String) {
        edit(DeskWorkspaceEdit([snapshot.file: edits]), what())
        if DeskWorkspaceEdit.normalize(edits) != edits { problems.append("\(what()): edits not sorted or overlapping") }
    }

    mutating func diagnostics(_ list: [DeskServiceDiagnostic], _ what: String) {
        for d in list {
            range(d.range, file: d.file, "\(what) \(d.id.rawValue)")
            for note in d.notes { if let l = note.location { location(l, "\(what) \(d.id.rawValue) note") } }
            for fix in d.fixIts { edit(fix.edit, "\(what) \(d.id.rawValue) fix-it") }
            if let dropped = d.dropped { location(dropped.location, "\(what) \(d.id.rawValue) dropped") }
            if d.message.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(what) \(d.id.rawValue): no message") }
            for fix in d.fixIts where fix.title.isEmpty { problems.append("\(what) \(d.id.rawValue): a fix-it with no title") }
        }
    }

    mutating func tokens(_ tokens: DeskSemanticTokens, _ what: String) {
        var reached = 0
        for token in tokens.tokens {
            range(token.range, "\(what) token")
            if token.range.start.offset < reached { problems.append("\(what): token \(token) overlaps or is out of order") }
            if token.range.isEmpty { problems.append("\(what): empty token \(token)") }
            reached = token.range.end.offset
        }
        if tokens.data.count % 5 != 0 { problems.append("\(what): data not in fives") }
    }

    mutating func outline(_ items: [DeskDocumentSymbol], _ what: String) {
        for item in items {
            range(item.range, "\(what) \(item.name)")
            range(item.selectionRange, "\(what) \(item.name) selection")
            outline(item.children, what)
        }
    }

    mutating func folding(_ folds: [DeskFoldingRange], _ what: String) {
        for fold in folds {
            range(fold.range, "\(what) fold")
            if fold.startLine >= fold.endLine { problems.append("\(what): fold \(fold) of one line") }
        }
    }

    mutating func element(_ hit: DeskElementHit, _ what: String) {
        range(hit.range, "\(what) element")
        range(hit.callRange, "\(what) call")
        if let loop = hit.loopRange { range(loop, "\(what) loop") }
    }
}

extension Hasher {
    /// An element hit without its node references (they change with every parse).
    mutating func combine(fuzzElement hit: DeskElementHit?) {
        guard let hit else { combine(0); return }
        combine(hit.component)
        combine(hit.name)
        combine(hit.range)
        combine(hit.callRange)
        combine(hit.loopRange)
    }

    mutating func combine(fuzzOutline items: [DeskDocumentSymbol]) {
        combine(items.count)
        for item in items {
            combine(item.name)
            combine(item.detail)
            combine(item.kind)
            combine(item.range)
            combine(item.selectionRange)
            combine(fuzzOutline: item.children)
        }
    }
}

/// The results that do not depend on a position, checked and hashed.
func deskFuzzWholeFile(_ snapshot: DeskSnapshot, _ probe: inout DeskFuzzProbe) -> Int {
    var h = Hasher()
    let diagnostics = snapshot.diagnostics
    probe.diagnostics(diagnostics, "diagnostics")
    h.combine(diagnostics)
    let package = snapshot.packageDiagnostics
    probe.diagnostics(package, "package diagnostics")
    h.combine(package)
    h.combine(snapshot.problemCounts())
    let folder = snapshot.packageCheck().folderDiagnostics.map(snapshot.serviceDiagnostic)
    probe.diagnostics(folder, "folder diagnostics")
    h.combine(folder)
    h.combine(snapshot.folderProblemCounts())
    let outline = snapshot.documentSymbols()
    probe.outline(outline, "outline")
    h.combine(fuzzOutline: outline)
    let folds = snapshot.foldingRanges()
    probe.folding(folds, "folding")
    h.combine(folds)
    let tokens = snapshot.semanticTokens()
    probe.tokens(tokens, "tokens")
    h.combine(tokens)
    let format = snapshot.formatDocument()
    probe.edits(format, "format")
    h.combine(format)
    for action in snapshot.sourceActions() {
        probe.edit(action.edit, "source action")
        h.combine(action)
    }
    for group in Set(diagnostics.flatMap { $0.fixIts.compactMap(\.group) }).sorted() {
        probe.edit(snapshot.fixAll(group: group), "fix all \(group)")
        h.combine(snapshot.fixAll(group: group))
        if let action = snapshot.fixAllAction(group: group) { h.combine(action) }
    }
    for d in diagnostics.prefix(40) {
        for action in snapshot.codeActions(for: d) {
            probe.edit(action.edit, "actions of \(d.id.rawValue)")
            h.combine(action)
        }
    }
    let elements = snapshot.elements()
    for element in elements {
        probe.element(element, "elements")
        h.combine(fuzzElement: element)
        if let again = snapshot.range(of: element.element), again.range != element.range {
            probe.problems.append("element \(element.component) found at \(again.range), listed at \(element.range)")
        }
    }
    return h.finalize()
}

/// With `DESK_FUZZ_PROFILE`, the time each request takes, summed over a run (printed per case).
struct DeskFuzzClock {
    static var enabled = ProcessInfo.processInfo.environment["DESK_FUZZ_PROFILE"] != nil
    static var totals: [String: Double] = [:]
    var last = ProcessInfo.processInfo.systemUptime

    mutating func lap(_ name: String) {
        guard Self.enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        Self.totals[name, default: 0] += now - last
        last = now
    }

    static func report() -> String {
        defer { totals = [:] }
        return totals.sorted { $0.value > $1.value }.prefix(5).map { String(format: "%@ %.2f s", $0.key, $0.value) }.joined(separator: ", ")
    }
}

/// Which rename places get a rename: the first ones met, while a budget lasts, or the ones a first run chose.
enum DeskFuzzRenames {
    case budget(Int, chosen: Set<Int>)
    case at(Set<Int>)

    /// Whether to rename the place that starts at `offset` (a budget is spent and the offset kept).
    mutating func take(_ offset: Int) -> Bool {
        switch self {
        case .budget(let left, var chosen):
            guard left > 0 else { return false }
            chosen.insert(offset)
            self = .budget(left - 1, chosen: chosen)
            return true
        case .at(let offsets):
            return offsets.contains(offset)
        }
    }

    var chosen: Set<Int> {
        switch self {
        case .budget(_, let chosen): return chosen
        case .at(let offsets): return offsets
        }
    }
}

/// Every position request at one offset, checked and hashed. A rename is made at the start of a rename place when
/// `renames` takes it.
func deskFuzzAsk(_ snapshot: DeskSnapshot, at offset: Int, _ probe: inout DeskFuzzProbe, renames: inout DeskFuzzRenames) -> Int {
    var h = Hasher()
    let position = snapshot.index.position(utf16: offset)
    let length = snapshot.index.utf16Count
    let at = "at \(offset)"

    var clock = DeskFuzzClock()
    let list = snapshot.completions(at: position)
    probe.range(list.context.range, "completion context \(at)")
    for item in list.items {
        probe.range(item.range, "completion \(item.label) \(at)")
        probe.edits(item.additionalEdits, "completion \(item.label) edits \(at)")
    }
    h.combine(list)

    clock.lap("completion")
    if let hover = snapshot.hover(at: position) {
        probe.range(hover.range, "hover \(at)")
        h.combine(hover)
        h.combine(hover.markdown(.english))
        h.combine(hover.markdown(.simplifiedChinese))
    } else {
        h.combine(0)
    }

    clock.lap("hover")
    if let help = snapshot.signatureHelp(at: position) {
        probe.range(help.range, "signature \(at)")
        if help.activeSignature < 0 || help.activeSignature >= max(1, help.signatures.count) {
            probe.problems.append("signature \(at): active signature \(help.activeSignature) of \(help.signatures.count)")
        }
        if let p = help.activeParameter, help.signatures.indices.contains(help.activeSignature),
           p < 0 || p >= help.signatures[help.activeSignature].parameters.count {
            probe.problems.append("signature \(at): active parameter \(p)")
        }
        for signature in help.signatures {
            let count = signature.label.utf16.count
            for parameter in signature.parameters where parameter.labelRange.lowerBound < 0 || parameter.labelRange.upperBound > count {
                probe.problems.append("signature \(at): parameter \(parameter.name) outside its label")
            }
        }
        h.combine(help)
        h.combine(help.markdown(.english))
    } else {
        h.combine(0)
    }

    clock.lap("signature")
    let definition = snapshot.definition(at: position)
    for l in definition { probe.location(l, "definition \(at)") }
    h.combine(definition)
    clock.lap("definition")
    let references = snapshot.references(at: position)
    for l in references { probe.location(l, "references \(at)") }
    h.combine(references)
    clock.lap("references")
    let highlights = snapshot.documentHighlights(at: position)
    for highlight in highlights { probe.range(highlight.range, "highlight \(at)") }
    h.combine(highlights)
    if let info = snapshot.symbol(at: position) {
        probe.range(info.range, "symbol \(at)")
        h.combine(info)
    }

    clock.lap("highlights")
    switch snapshot.prepareRename(at: position) {
    case .success(let place):
        probe.range(place.range, "rename place \(at)")
        h.combine(place)
        if place.range.start.offset == offset, renames.take(offset) {
            let result = snapshot.rename(at: position, to: "fuzzedName")
            if case .success(let rename) = result { probe.edit(rename.edit, "rename \(at)") }
            h.combine(result)
        }
    case .failure(let refusal):
        h.combine(refusal)
    }

    clock.lap("rename")
    let hit = snapshot.elementAt(position)
    if let hit { probe.element(hit, "element \(at)") }
    h.combine(fuzzElement: hit)

    let span = snapshot.index.range(utf16: offset..<min(length, offset + 9))
    clock.lap("element")
    for action in snapshot.codeActions(in: span, source: false) {
        probe.edit(action.edit, "code action \(at)")
        h.combine(action)
    }
    clock.lap("code actions")
    let tokens = snapshot.semanticTokens(in: span)
    probe.tokens(tokens, "range tokens \(at)")
    h.combine(tokens)
    clock.lap("range tokens")
    let widened = snapshot.formattingRange(for: DeskRange(start: position, end: position))
    probe.range(widened, "formatting range \(at)")
    let format = snapshot.formatRange(span)
    probe.edits(format, "range format \(at)")
    h.combine(format)
    clock.lap("formatting")
    return h.finalize()
}

/// The offsets a case is asked at: every offset of a text of up to `budget` offsets; otherwise evenly spaced ones and
/// its tokens' ends (evenly sampled), `budget` in all, and both ends of the text.
func deskFuzzOffsets(_ snapshot: DeskSnapshot, budget: Int) -> [Int] {
    let length = snapshot.index.utf16Count
    if length + 1 <= budget { return Array(0...length) }
    let half = max(1, budget / 2)
    var offsets = Set(Swift.stride(from: 0, through: length, by: max(1, (length + half) / half)))
    offsets.insert(length)
    var ends: [Int] = []
    for token in deskNavTokenStarts(snapshot.tree) {
        ends.append(snapshot.index.utf16Offset(ofUTF8: token.lowerBound))
        ends.append(snapshot.index.utf16Offset(ofUTF8: token.upperBound))
    }
    let step = max(1, (ends.count + half - 1) / half)
    for k in Swift.stride(from: 0, to: ends.count, by: step) { offsets.insert(ends[k]) }
    return offsets.sorted()
}

/// What one case found: its problems, how many offsets were asked, and the hashes of the answers.
struct DeskFuzzRun {
    var problems: [String] = []
    var offsets: [Int] = []
    var hashes: [Int] = []
    var wholeFile = 0
    /// Where renames were made.
    var renamed: Set<Int> = []
}

/// Asks every request of a case's snapshot; `offsets` nil: the case's own. `renamed`: rename only there.
func deskFuzzRequests(_ c: DeskFuzzCase, offsets: [Int]? = nil, renamed: Set<Int>? = nil) -> DeskFuzzRun {
    let snapshot = c.service().snapshot
    var probe = DeskFuzzProbe(snapshot)
    var run = DeskFuzzRun()
    if (snapshot.text as NSString).length != snapshot.index.utf16Count {
        probe.problems.append("the index counts \(snapshot.index.utf16Count) units, NSString \((snapshot.text as NSString).length)")
    }
    run.wholeFile = deskFuzzWholeFile(snapshot, &probe)
    run.offsets = offsets ?? deskFuzzOffsets(snapshot, budget: c.maxOffsets)
    var renames = renamed.map { DeskFuzzRenames.at($0) } ?? .budget(c.renames, chosen: [])
    for offset in run.offsets {
        run.hashes.append(deskFuzzAsk(snapshot, at: offset, &probe, renames: &renames))
    }
    run.renamed = renames.chosen
    run.problems = probe.problems
    return run
}

/// The pieces updates insert: every bracket, quotes, each line break, a byte order mark, emoji, bidirectional marks,
/// full-width punctuation and a start of a comment.
let deskFuzzInsertions = ["{", "}", "(", ")", "[", "]", "\"", "\"\"\"", "\n", "\r\n", "\r", "\u{FEFF}", "😀", "👩‍👩‍👧",
                          "\u{202E}", "\u{2067}", "\u{200F}", "（", "｝", "：", "＂", "「", ".", ",", "a", "/*", "//", "{x}",
                          "\\", "#", "\u{3000}", "\u{0}", "\u{2028}", "é", "e\u{301}"]

/// Updates at every offset (at most `maxUpdates`, evenly spaced): a piece is inserted and taken out again with
/// syntax-only updates (`beginUpdate`), and every `checkEvery`-th insertion is also checked and compared with a
/// service opened on the same text. Then ranges that split surrogate pairs, run past the end or start before it, and
/// one change back to the start.
func deskFuzzUpdates(_ c: DeskFuzzCase) -> (problems: [String], updates: Int) {
    let service = c.service()
    let original = service.text
    let originalIndex = service.snapshot.index
    let length = originalIndex.utf16Count
    var problems: [String] = []
    var updates = 0
    var version = 1
    func expectText(_ snapshot: DeskSnapshot, _ expected: String, _ what: String) {
        if snapshot.text != expected {
            problems.append("\(what): text differs (\(snapshot.text.utf16.count) units, expected \(expected.utf16.count))")
        }
        if snapshot.index.utf16Count != (expected as NSString).length { problems.append("\(what): index length differs") }
    }
    func checkSyntax(_ snapshot: DeskSnapshot, _ what: String) {
        var probe = DeskFuzzProbe(snapshot)
        var clock = DeskFuzzClock()
        probe.diagnostics(snapshot.diagnostics, what)
        clock.lap("syntax: diagnostics")
        probe.tokens(snapshot.semanticTokens(), what)
        clock.lap("syntax: tokens")
        probe.folding(snapshot.foldingRanges(), what)
        clock.lap("syntax: folding")
        probe.outline(snapshot.documentSymbols(), what)
        clock.lap("syntax: outline")
        let middle = snapshot.index.position(utf16: snapshot.index.utf16Count / 2)
        _ = snapshot.completions(at: middle)
        clock.lap("syntax: completion")
        _ = snapshot.hover(at: middle)
        clock.lap("syntax: hover")
        problems += probe.problems.prefix(3)
    }
    func compareWithFresh(_ snapshot: DeskSnapshot, _ what: String) {
        var files = c.files
        files[c.file] = snapshot.text
        var fresh = c
        fresh.files = files
        if let package = c.package {
            fresh.package = package.settingText(snapshot.text, of: DeskFileID(path: c.file))
        }
        let other = fresh.service().snapshot
        if other.diagnostics != snapshot.diagnostics {
            problems.append("\(what): diagnostics differ from a fresh service (\(snapshot.diagnostics.count) / \(other.diagnostics.count))")
        }
        if other.semanticTokens() != snapshot.semanticTokens() { problems.append("\(what): highlighting differs from a fresh service") }
        if other.foldingRanges() != snapshot.foldingRanges() { problems.append("\(what): folding differs from a fresh service") }
    }
    var k = 0
    var clock = DeskFuzzClock()
    let step = max(1, (length + c.maxUpdates) / max(1, c.maxUpdates))
    for offset in Swift.stride(from: 0, through: length, by: step) {
        let piece = deskFuzzInsertions[k % deskFuzzInsertions.count]
        let at = originalIndex.clampedUTF16(offset)
        let inserted = (original as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: piece)
        let pending = service.beginUpdate(changes: [DeskTextChange(range: offset..<offset, text: piece)], version: version)
        version += 1
        updates += 1
        clock.lap("update: begin")
        expectText(pending.snapshot, inserted, "insert \(piece.debugDescription) at \(offset)")
        if pending.snapshot.isChecked { problems.append("insert at \(offset): a syntax-only snapshot says it is checked") }
        checkSyntax(pending.snapshot, "syntax after inserting at \(offset)")
        clock.lap("update: syntax requests")
        if k % max(1, c.checkEvery) == 0 {
            if let checked = service.accept(pending.run()) {
                checkSyntax(checked, "checked after inserting at \(offset)")
                compareWithFresh(checked, "insert at \(offset)")
            } else {
                problems.append("insert at \(offset): the latest check was dropped")
            }
        }
        clock.lap("update: check and compare")
        let removed = service.beginUpdate(changes: [DeskTextChange(range: at..<(at + piece.utf16.count), text: "")], version: version)
        version += 1
        updates += 1
        expectText(removed.snapshot, original, "remove \(piece.debugDescription) at \(offset)")
        clock.lap("update: begin")
        k += 1
    }
    // Ranges that split a surrogate pair, run past the end, start before the start or are huge, replaced at once.
    var random = DeskRandom(seed: UInt64(truncatingIfNeeded: original.utf16.count &* 31 &+ 7))
    var text = service.text
    let bounds = [-7, 0, 1, length / 3, length / 2, length - 1, length, length + 3, Int.max / 4]
    for round in 0..<c.replacements {
        let a = random.pick(bounds) + random.int(3)
        let b = random.pick(bounds) + random.int(3)
        let lower = min(a, b)
        let upper = max(a, b)
        let piece = deskFuzzInsertions[random.int(deskFuzzInsertions.count)]
        let index = DeskTextIndex(text)
        let from = index.clampedUTF16(lower)
        let to = max(from, index.clampedUTF16(upper))
        let expected = (text as NSString).replacingCharacters(in: NSRange(location: from, length: to - from), with: piece)
        let snapshot = service.update(changes: [DeskTextChange(range: lower..<upper, text: piece)], version: version)
        version += 1
        updates += 1
        expectText(snapshot, expected, "replace \(lower)..<\(upper) (round \(round))")
        text = snapshot.text
    }
    clock.lap("update: replace ranges")
    checkSyntax(service.snapshot, "after replacing ranges")
    compareWithFresh(service.snapshot, "after replacing ranges")
    // Back to the start with one change of the whole text, as a text view's undo of everything would.
    let back = service.update(changes: [DeskTextChange(range: 0..<text.utf16.count, text: original)], version: version)
    expectText(back, original, "undo everything")
    compareWithFresh(back, "undo everything")
    return (problems, updates)
}

/// Positions and ranges no text view gives: negative, past the end, huge, inside a surrogate pair, reversed, and
/// positions whose line and column disagree with their offset. Requests clamp them.
func deskFuzzHostilePositions(_ snapshot: DeskSnapshot) -> [String] {
    var probe = DeskFuzzProbe(snapshot)
    let length = snapshot.index.utf16Count
    var offsets = [Int.min, -1_000_000, -1, length + 1, length + 1_000, Int.max, Int.max - 1]
    // Inside a surrogate pair, when there is one.
    if let pair = snapshot.text.utf16.firstIndex(where: { UTF16.isLeadSurrogate($0) }) {
        offsets.append(snapshot.text.utf16.distance(from: snapshot.text.utf16.startIndex, to: pair) + 1)
    }
    var renames = DeskFuzzRenames.budget(1, chosen: [])
    for offset in offsets {
        for (line, column) in [(0, 0), (-5, -5), (Int.max, Int.max), (3, 1_000_000)] {
            let position = DeskPosition(offset: offset, line: line, column: column)
            _ = snapshot.completions(at: position)
            _ = snapshot.hover(at: position)
            _ = snapshot.signatureHelp(at: position)
            _ = snapshot.definition(at: position)
            _ = snapshot.references(at: position)
            _ = snapshot.documentHighlights(at: position)
            _ = snapshot.prepareRename(at: position)
            _ = snapshot.rename(at: position, to: "hostileName")
            _ = snapshot.elementAt(position)
            _ = snapshot.symbol(at: position)
            _ = snapshot.completionContext(at: position)
            var range = DeskRange(start: position, end: position)
            _ = snapshot.codeActions(in: range)
            _ = snapshot.semanticTokens(in: range)
            _ = snapshot.formatRange(range)
            _ = snapshot.formattingRange(for: range)
            // A range made reversed after it was built.
            range.end = DeskPosition(offset: offset == Int.min ? 0 : offset / 2 - 3, line: 0, column: 0)
            _ = snapshot.codeActions(in: range)
            _ = snapshot.semanticTokens(in: range)
            _ = snapshot.formatRange(range)
            _ = snapshot.formattingRange(for: range)
            _ = snapshot.formatRange(range.nsRange)
        }
        let clamped = snapshot.index.position(utf16: offset)
        probe.position(clamped, file: snapshot.file, "clamped \(offset)")
        _ = deskFuzzAsk(snapshot, at: min(max(offset, 0), length), &probe, renames: &renames)
    }
    for ns in [NSRange(location: NSNotFound, length: 0), NSRange(location: length, length: 50), NSRange(location: -3, length: 2),
               NSRange(location: Int.max - 2, length: 5), NSRange(location: 0, length: -4)] {
        _ = snapshot.formatRange(ns)
        _ = snapshot.index.range(ns)
    }
    return probe.problems
}

// MARK: - Texts

/// The hostile texts (§2.11 rule 7): 10,000 unclosed braces of each kind, deep nesting, long chains, a 32k text and
/// one over the limit, every kind of line break, byte order marks, emoji, bidirectional marks, full-width punctuation,
/// control characters and deterministic random soup.
///
/// The cases come in three groups (one suite each, so that each stays well inside the self-test's time limit):
/// 0, brackets that never close; 1, nesting and long texts; 2, line breaks, marks, punctuation, control characters,
/// soup and packages.
func deskFuzzHostileCases(group: Int? = nil) -> [DeskFuzzCase] {
    var cases: [DeskFuzzCase] = []
    var current = 0
    func add(_ label: String, _ text: String, file: String = "Test.desk", offsets: Int = 2_000, updates: Int = 16,
             checkEvery: Int = 16, others: [String: String] = [:]) {
        guard group == nil || group == current else { return }
        var files = others
        files[file] = text
        var c = DeskFuzzCase(label, file: file, files: files)
        c.maxOffsets = offsets
        c.maxUpdates = updates
        c.checkEvery = checkEvery
        // Checking hostile texts is slow in a debug build: a few replacements, each checked.
        c.replacements = text.utf16.count > 4_000 ? 2 : 6
        c.askedAgain = 16
        cases.append(c)
    }
    let month = deskNavFixture("Acceptance/MonthView.desk")
    let cpu = deskNavFixture("Acceptance/CPU.desk")

    // 10,000 unclosed braces, parentheses and brackets; opened blocks that never close.
    add("10,000 unclosed braces", "widget {\n" + String(repeating: "{", count: 10_000), offsets: 12_000, updates: 24)
    add("10,000 unclosed parentheses", "widget {\n    Text(" + String(repeating: "(", count: 10_000))
    add("10,000 unclosed brackets", "widget {\n    variable a = " + String(repeating: "[", count: 10_000))
    add("10,000 unclosed blocks", "widget {\n" + String(repeating: "Column {\n", count: 10_000))
    add("10,000 closing braces", "widget {\n" + String(repeating: "}", count: 10_000))
    add("unclosed interpolations", "widget {\n    Text(\"" + String(repeating: "{\"", count: 2_000))

    // Deep nesting, closed: blocks, brackets, interpolations, long chains.
    current = 1
    add("3,000 nested blocks", "widget {\n" + String(repeating: "Column {\n", count: 3_000) + "Text(\"A\")\n"
        + String(repeating: "}\n", count: 3_000) + "}\n")
    add("2,000 nested parentheses", "widget {\n    Text(\"{" + String(repeating: "(", count: 2_000) + "1"
        + String(repeating: ")", count: 2_000) + "}\")\n}\n")
    add("200 nested interpolations", "widget {\n    Text(" + String(repeating: "\"{", count: 200) + "1"
        + String(repeating: "}\"", count: 200) + ")\n}\n")
    add("a 2,000-member chain", "widget {\n    Text(\"{" + (["weather"] + Array(repeating: "now", count: 2_000)).joined(separator: ".")
        + "}\")\n}\n")
    add("a 2,000-term sum", "widget {\n    variable a = 1\n    computed b = " + Array(repeating: "a", count: 2_000).joined(separator: " + ")
        + "\n    Text(\"{b}\")\n}\n")
    add("500 else ifs", "widget {\n    variable a = 1\n    if a == 1 { Text(\"x\") }"
        + (2..<500).map { " else if a == \($0) { Text(\"y\") }" }.joined() + "\n}\n")
    add("a 1,000-call chain", "widget {\n    Text(\"A\")" + String(repeating: ".padding(1)", count: 1_000) + "\n}\n")
    add("500 nested ternaries", "widget {\n    variable a = 1\n    Text(\"{" + String(repeating: "a == 1 ? 1 : ", count: 500) + "0}\")\n}\n")

    // Texts at and over the limit of 32,768 units, of ASCII and of surrogate pairs.
    add("a 32k text", "widget {\n    Text(\"" + String(repeating: "x", count: 32_768) + "\")\n}\n")
    add("a text over 32k", "widget {\n    Text(\"" + String(repeating: "y", count: 32_769) + "\")\n}\n")
    add("a 32k text of emoji", "widget {\n    Text(\"" + String(repeating: "😀", count: 16_384) + "\")\n}\n")
    add("a 32k comment", "// " + String(repeating: "z", count: 32_768) + "\nwidget {\n    Text(\"A\")\n}\n")
    add("a 100,000-letter name", "widget {\n    variable " + String(repeating: "n", count: 100_000) + " = 1\n}\n")

    // Line breaks, byte order marks.
    current = 2
    add("CR LF", month.replacingOccurrences(of: "\n", with: "\r\n"), updates: 400)
    add("lone CR", cpu.replacingOccurrences(of: "\n", with: "\r"), updates: 400)
    add("mixed line breaks", month.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        .map { $0.element + ["\n", "\r\n", "\r", "\n\r"][$0.offset % 4] }.joined(), updates: 400)
    add("byte order marks", "\u{FEFF}" + cpu.replacingOccurrences(of: "\n\n", with: "\n\u{FEFF}\n")
        .replacingOccurrences(of: "\"", with: "\"\u{FEFF}"), updates: 400)
    add("only a byte order mark", "\u{FEFF}")
    add("empty", "")
    for (k, tiny) in ["{", "}", "\"", "\r", "\r\n", "\n\r", "😀", "\u{202E}", "（", "/*", "\"{", "widget", "widget {", "info {"].enumerated() {
        add("tiny \(k)", tiny)
    }

    // Emoji, bidirectional marks and full-width punctuation in names, texts, comments and between tokens.
    let emoji = ["😀", "👩‍👩‍👧", "🇨🇳", "👍🏽", "𝄞", "🧑‍💻", "1️⃣"]
    add("emoji", "widget {\n    variable 😀 = 1\n    // 👩‍👩‍👧 family 🇨🇳\n    Text(\"\(emoji.joined()) {😀}\").font(.caption)👍🏽\n"
        + "    Text(\"𝄞\")\n    🧑‍💻Text(\"1️⃣\")\n    Text(\"{weather.now.temperature} 🌡\")\n}\n")
    add("emoji inside tokens", month.replacingOccurrences(of: "Text", with: "Te😀xt").replacingOccurrences(of: "{", with: "{👩‍👩‍👧"), updates: 400)
    let bidi = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
                "\u{200E}", "\u{200F}", "\u{061C}"]
    add("bidirectional marks", "widget {\n    variable a\u{202E} = 1\n    // \u{2067}comment\u{2069}\n    Text(\"\(bidi.joined())\")\n"
        + "    Text(\"{a}\u{200F}\")\u{202E}.padding(8)\n    \u{2066}Text(\"B\")\n}\n")
    add("bidirectional marks everywhere", bidi.enumerated().reduce(cpu) { text, mark in
        text.replacingOccurrences(of: ["(", ")", ".", "{", "\"", ":", " = ", "}", ",", "//", "[", "]"][mark.offset], with: mark.element + ["(", ")", ".", "{", "\"", ":", " = ", "}", ",", "//", "[", "]"][mark.offset])
    }, updates: 400)
    add("full-width punctuation", "widget｛\n    Text（＂A＂）．font（．caption）\n    variable ｂ ＝ １\n    Text（「B」）\n"
        + "    Row（spacing：８）｛ Text（＂C＂），Text(\"D\") ｝\n\u{3000}\u{3000}Text(\"E\")；Text(\"F\")\n｝\n")
    add("full-width everywhere", month.replacingOccurrences(of: "(", with: "（").replacingOccurrences(of: ")", with: "）")
        .replacingOccurrences(of: "{", with: "｛").replacingOccurrences(of: "}", with: "｝").replacingOccurrences(of: ":", with: "：")
        .replacingOccurrences(of: "\"", with: "＂").replacingOccurrences(of: ",", with: "，"), updates: 400)

    // Control characters and separators Desk does not treat as line breaks.
    add("control characters", "widget {\u{0}\n    Text(\"A\u{0}B\")\u{0B}\n\u{0C}    Text(\"\u{FFFD}\u{FFFF}\u{E000}\")\u{2028}\u{2029}\u{0085}\n"
        + "\tText(\"\u{1}\u{7F}\u{9F}\")\n}\u{0}")

    // Deterministic random soup of every piece above and pieces of Desk.
    var random = DeskRandom(seed: 0xDE5C)
    let pieces = deskFuzzInsertions + emoji + bidi + ["widget ", "info ", "Text(", "Column ", "variable ", "computed ", " = ",
                                                      "options.", ".padding(", "for ", " in ", "if ", "else ", "1s", "50%",
                                                      "\"{", "}\"", "weather.", "cpu.", "style ", "package ", "translations "]
    for k in 0..<4 {
        var soup = ""
        for _ in 0..<(k == 0 ? 4_000 : 600) { soup += random.pick(pieces) }
        add("random soup \(k)", soup)
    }

    // The package file hostile, and a hostile package beside a widget.
    add("hostile package.desk", "package {\n    name: \"\u{202E}😀\"\n" + String(repeating: "{", count: 2_000) + "\n", file: "package.desk")
    add("widget beside a hostile package", cpu,
        others: ["package.desk": "package {\n    name: \"（＂\"\n    options {\n" + String(repeating: "(", count: 3_000) + "\n",
                 "Other.desk": "widget {\n" + String(repeating: "{", count: 1_000)])
    return cases
}

/// The acceptance widgets, the Harbor package opened as a loaded folder, and the fixtures of formatting and syntax.
func deskFuzzAcceptanceCases() -> [DeskFuzzCase] {
    var cases: [DeskFuzzCase] = []
    for file in deskFixtureFiles() where !file.path.hasPrefix("Diagnostics/") && !file.path.hasPrefix("Packages/") {
        let name = (file.path as NSString).lastPathComponent == "package.desk" ? "package.desk" : "Test.desk"
        var c = DeskFuzzCase(file.path, file: name, text: file.text)
        // Every offset of the acceptance widgets gets an update; one in 32 is checked.
        c.maxUpdates = file.path.hasPrefix("Acceptance/") ? 2_000 : 120
        c.checkEvery = file.path.hasPrefix("Acceptance/") ? 32 : 16
        cases.append(c)
    }
    let harbor = deskHarbor()
    for file in harbor.texts.keys.sorted(by: { $0.path < $1.path }) {
        var c = DeskFuzzCase("Harbor/\(file.path)", file: file.path, files: [:])
        c.package = harbor
        c.files = Dictionary(uniqueKeysWithValues: harbor.texts.map { ($0.key.path, $0.value) })
        c.maxUpdates = 300
        cases.append(c)
    }
    return cases
}

/// Every diagnostic fixture: its positive and negative parts with the package and folder files it declares, and its
/// package on its own.
func deskFuzzFixtureCases() -> [DeskFuzzCase] {
    var cases: [DeskFuzzCase] = []
    for fixtureFile in deskFixtureFiles("Diagnostics") {
        let fixture = DeskDiagnosticFixture.parse(path: fixtureFile.path, text: fixtureFile.text)
        let file = fixture.fileName
        var parts = [fixture.generate.map(deskGeneratedText) ?? fixture.positive]
        if let negative = fixture.negative { parts.append(negative) }
        for (k, part) in parts.enumerated() {
            var files = [file: part]
            if let package = fixture.package, file != "package.desk" { files["package.desk"] = package }
            for extra in fixture.folderFiles where extra.name.hasSuffix(".desk") { files[extra.name] = extra.text }
            var c = DeskFuzzCase("\(fixture.id)\(k == 0 ? "+" : "-")", file: file, files: files)
            // Generated inputs are large: sampled offsets and fewer updates.
            if fixture.generate != nil {
                c.maxOffsets = 1_500
                c.maxUpdates = 24
            } else {
                c.maxUpdates = 60
            }
            c.checkEvery = 16
            c.replacements = 4
            c.askedAgain = 16
            c.renames = 8
            cases.append(c)
        }
        if let package = fixture.package {
            var c = DeskFuzzCase("\(fixture.id) package", file: "package.desk", text: package)
            c.maxUpdates = 60
            c.checkEvery = 16
            c.replacements = 4
            c.askedAgain = 16
            c.renames = 8
            cases.append(c)
        }
    }
    return cases
}

/// Sampled corpus snippets: the 40 longest and 160 spread evenly over the rest.
func deskFuzzCorpusCases() -> [DeskFuzzCase] {
    let corpus = deskExampleCorpus()
    let byLength = corpus.indices.sorted { corpus[$0].utf16.count > corpus[$1].utf16.count }
    let longest = Set(byLength.prefix(40))
    let rest = corpus.indices.filter { !longest.contains($0) }
    var picked = longest.sorted()
    if !rest.isEmpty {
        let step = max(1, rest.count / 160)
        picked += Swift.stride(from: 0, to: rest.count, by: step).prefix(160).map { rest[$0] }
    }
    return picked.map { k in
        var c = DeskFuzzCase("corpus \(k)", text: corpus[k])
        c.maxUpdates = 60
        c.checkEvery = 16
        c.replacements = 4
        c.askedAgain = 16
        c.renames = 6
        return c
    }
}

// MARK: - Suites

/// Runs every request of each case at its offsets, the updates, the hostile positions, and a second service's answers
/// at every `determinismStride`-th offset; one check per case.
func deskFuzzSuite(_ t: TestRunner, _ cases: [DeskFuzzCase], determinismStride: Int) {
    let only = ProcessInfo.processInfo.environment["DESK_FUZZ_ONLY"]
    let verbose = ProcessInfo.processInfo.environment["DESK_FUZZ_VERBOSE"] != nil
    var positions = 0
    var updates = 0
    var renames = 0
    var compared = 0
    var slowest = (0.0, "")
    for c in cases where only.map({ c.label.contains($0) }) ?? true {
        let start = ProcessInfo.processInfo.systemUptime
        var phases: [Double] = []
        func phase() { phases.append(ProcessInfo.processInfo.systemUptime - start - phases.reduce(0, +)) }
        let first = deskFuzzRequests(c)
        phase()
        var problems = first.problems
        positions += first.offsets.count
        renames += first.renamed.count
        // Determinism: a second service opened on the same folder answers the same.
        let sampled = first.offsets.enumerated().filter { $0.offset % max(1, determinismStride) == 0 }
        let second = deskFuzzRequests(c, offsets: sampled.map(\.element), renamed: first.renamed)
        phase()
        compared += sampled.count
        if second.wholeFile != first.wholeFile { problems.append("the whole-file results differ between two services") }
        for (k, (i, offset)) in sampled.enumerated() where second.hashes[k] != first.hashes[i] {
            problems.append("the answers at \(offset) differ between two services")
            break
        }
        // The same snapshot asked again (its caches warm) answers the same.
        let snapshot = c.service().snapshot
        var probe = DeskFuzzProbe(snapshot)
        var none = DeskFuzzRenames.at(first.renamed)
        for (i, offset) in sampled.prefix(c.askedAgain) {
            let once = deskFuzzAsk(snapshot, at: offset, &probe, renames: &none)
            let twice = deskFuzzAsk(snapshot, at: offset, &probe, renames: &none)
            if once != twice || once != first.hashes[i] {
                problems.append("the answers at \(offset) change when asked again")
                break
            }
        }
        phase()
        problems += deskFuzzHostilePositions(snapshot)
        phase()
        let (updateProblems, count) = deskFuzzUpdates(c)
        phase()
        problems += updateProblems
        updates += count
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if elapsed > slowest.0 { slowest = (elapsed, c.label) }
        if verbose {
            print(String(format: "      %@: %d offsets, %d updates, %.2f s (requests %.2f, second service %.2f, again %.2f, hostile positions %.2f, updates %.2f)",
                         c.label, first.offsets.count, count, elapsed, phases[0], phases[1], phases[2], phases[3], phases[4]))
        }
        if DeskFuzzClock.enabled { print("        " + DeskFuzzClock.report()) }
        t.check(problems.isEmpty, "\(c.label): \(problems.count) problems: \(problems.prefix(6))")
    }
    print("    \(positions) offsets asked every request, \(compared) compared with a second service, \(renames) renames, "
          + "\(updates) updates; slowest: \(slowest.1) (\(String(format: "%.1f", slowest.0)) s)")
}

/// Runs `body` on a thread with a background queue's 512 KiB of stack and waits for it (at most ten minutes).
func deskOnSmallStack(_ body: @escaping () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        body()
        done.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    return done.wait(timeout: .now() + 600) == .success
}

func runDeskServiceFuzzTests(_ t: TestRunner) {
    t.suite("Desk: service — fuzz on a small stack") {
        // Every request on the hostile texts from a thread with a background queue's stack: the service's walkers
        // recurse into nested blocks, member chains and types, so deep input must move them to a larger stack.
        let only = ProcessInfo.processInfo.environment["DESK_FUZZ_ONLY"]
        var asked = 0
        // The hostile texts, and chains deeper than the fuzz suites' (asked at fewer offsets here).
        let deep = [
            DeskFuzzCase("a 5,000-member chain", text: "widget {\n    Text(\"{" + (["weather"] + Array(repeating: "now", count: 5_000)).joined(separator: ".") + "}\")\n}\n"),
            DeskFuzzCase("a 5,000-term sum", text: "widget {\n    variable a = 1\n    computed b = " + Array(repeating: "a", count: 5_000).joined(separator: " + ") + "\n    Text(\"{b}\")\n}\n"),
            DeskFuzzCase("a 3,000-call chain", text: "widget {\n    Text(\"A\")" + String(repeating: ".padding(1)", count: 3_000) + "\n}\n"),
            DeskFuzzCase("1,500 else ifs", text: "widget {\n    variable a = 1\n    if a == 1 { Text(\"x\") }" + (2..<1_500).map { " else if a == \($0) { Text(\"y\") }" }.joined() + "\n}\n"),
        ]
        for c in deskFuzzHostileCases() + deep where only.map({ c.label.contains($0) }) ?? true {
            let service = c.service()
            let snapshot = service.snapshot
            let length = snapshot.index.utf16Count
            // Evenly spaced offsets and the middle, where the nesting is deepest.
            var offsets = Set(Swift.stride(from: 0, through: length, by: max(1, length / 24)))
            for k in -3...3 { offsets.insert(min(max(length / 2 + k, 0), length)) }
            var problems: [String] = []
            let finished = deskOnSmallStack {
                var probe = DeskFuzzProbe(snapshot)
                _ = deskFuzzWholeFile(snapshot, &probe)
                var renames = DeskFuzzRenames.budget(2, chosen: [])
                for offset in offsets.sorted() { _ = deskFuzzAsk(snapshot, at: offset, &probe, renames: &renames) }
                // An update checked in the background.
                let pending = service.beginUpdate(changes: [DeskTextChange(range: length / 2..<length / 2, text: "{")], version: 2)
                _ = pending.run()
                _ = pending.snapshot.semanticTokens()
                _ = pending.snapshot.documentSymbols()
                problems = probe.problems
            }
            asked += offsets.count
            t.check(finished, "\(c.label) finishes")
            t.check(problems.isEmpty, "\(c.label): \(problems.prefix(4))")
        }
        print("    \(asked) offsets asked on a 512 KiB stack")
    }

    t.suite("Desk: service — fuzz: acceptance widgets, Harbor and fixtures of formatting") {
        deskFuzzSuite(t, deskFuzzAcceptanceCases(), determinismStride: 1)
    }
    // The fixtures in two halves (syntax, names and types; then the rest), each well inside the self-test's limit.
    t.suite("Desk: service — fuzz: diagnostic fixtures DK1–DK4") {
        deskFuzzSuite(t, deskFuzzFixtureCases().filter { $0.label < "DK5" }, determinismStride: 3)
    }
    t.suite("Desk: service — fuzz: diagnostic fixtures DK5–DK9") {
        deskFuzzSuite(t, deskFuzzFixtureCases().filter { $0.label >= "DK5" }, determinismStride: 3)
    }
    t.suite("Desk: service — fuzz: corpus snippets") {
        deskFuzzSuite(t, deskFuzzCorpusCases(), determinismStride: 3)
    }
    t.suite("Desk: service — fuzz: hostile input, brackets that never close") {
        deskFuzzSuite(t, deskFuzzHostileCases(group: 0), determinismStride: 5)
    }
    t.suite("Desk: service — fuzz: hostile input, nesting and long texts") {
        deskFuzzSuite(t, deskFuzzHostileCases(group: 1), determinismStride: 5)
    }
    t.suite("Desk: service — fuzz: hostile input, line breaks, marks and punctuation") {
        deskFuzzSuite(t, deskFuzzHostileCases(group: 2), determinismStride: 3)
    }
}

// MARK: - Queues and snapshots before their check

/// Compile time: every value that crosses queues is `Sendable` (a snapshot, a pending check and its result, the
/// options, every result of a request, the folder model and its checks). `DeskLanguageService` itself is not: one
/// queue owns it.
func deskServiceSendableTypes() {
    func sendable<T: Sendable>(_: T.Type) {}
    sendable(DeskSnapshot.self)
    sendable(DeskPendingCheck.self)
    sendable(DeskCheckedText.self)
    sendable(DeskServiceOptions.self)
    sendable(DeskPosition.self)
    sendable(DeskRange.self)
    sendable(DeskLocation.self)
    sendable(DeskTextChange.self)
    sendable(DeskTextEditU16.self)
    sendable(DeskWorkspaceEdit.self)
    sendable(DeskServiceDiagnostic.self)
    sendable(DeskProblemCount.self)
    sendable(DeskCompletionList.self)
    sendable(DeskCompletionContext.self)
    sendable(DeskHover.self)
    sendable(DeskSignatureHelp.self)
    sendable(DeskSymbolInfo.self)
    sendable(DeskHighlight.self)
    sendable(DeskRenamePlace.self)
    sendable(DeskRename.self)
    sendable(DeskRenameRefusal.self)
    sendable(DeskDocumentSymbol.self)
    sendable(DeskFoldingRange.self)
    sendable(DeskElementHit.self)
    sendable(DeskSemanticTokens.self)
    sendable(DeskSemanticRun.self)
    sendable(DeskCodeAction.self)
    sendable(DeskTextIndex.self)
    sendable(DeskPackage.self)
    sendable(CheckedDeskPackage.self)
    sendable(DeskPackageUses.self)
    sendable(DeskPackageLocales.self)
    sendable(DeskOptionsSchema.self)
    sendable(DeskInstallSummary.self)
    sendable(DeskConsent.self)
    sendable(DeskArchiveEntry.self)
    sendable(PackageResources.self)
    sendable(LocalPackageSource.self)
    sendable(InMemoryPackageSource.self)
}

func runDeskServiceQueueTests(_ t: TestRunner) {
    t.suite("Desk: service — one snapshot asked from many threads at once") {
        // A snapshot's caches are built on first use under locks: eight threads asking every request at once, each
        // cache still empty, answer as one thread asking them in turn.
        deskServiceSendableTypes()
        for path in ["Acceptance/MonthView.desk", "Acceptance/CPU.desk"] {
            let c = DeskFuzzCase(path, text: deskNavFixture(path))
            let serial = c.service().snapshot
            var probe = DeskFuzzProbe(serial)
            let length = serial.index.utf16Count
            let offsets = Array(Swift.stride(from: 0, through: length, by: max(1, length / 96)))
            var none = DeskFuzzRenames.at([])
            let expected = offsets.map { deskFuzzAsk(serial, at: $0, &probe, renames: &none) }
            let wholeExpected = deskFuzzWholeFile(serial, &probe)
            let shared = c.service().snapshot
            let lock = NSLock()
            var answers = [[Int]](repeating: [], count: 8)
            var wholes = [Int](repeating: 0, count: 8)
            DispatchQueue.concurrentPerform(iterations: 8) { k in
                var own = DeskFuzzProbe(shared)
                var renames = DeskFuzzRenames.at([])
                // Each thread starts at a different place, so the caches are raced for.
                let order = offsets.indices.map { offsets[($0 + k * 13) % offsets.count] }
                var got: [Int: Int] = [:]
                for offset in order { got[offset] = deskFuzzAsk(shared, at: offset, &own, renames: &renames) }
                let whole = deskFuzzWholeFile(shared, &own)
                lock.lock()
                answers[k] = offsets.map { got[$0] ?? 0 }
                wholes[k] = whole
                lock.unlock()
            }
            for k in 0..<8 {
                t.check(answers[k] == expected, "\(path): thread \(k) answers as one thread does")
                t.check(wholes[k] == wholeExpected, "\(path): thread \(k) whole-file results")
            }
            t.equal(probe.problems, [], path)
        }
    }

    t.suite("Desk: service — a snapshot before its check words its diagnostics as the check does") {
        // The parser leaves the Desk spelling of foreign code to the checker; a syntax-only snapshot fills it in.
        var compared = 0
        for c in deskFuzzFixtureCases() + deskFuzzHostileCases().filter({ ($0.files[$0.file]?.utf16.count ?? 0) < 20_000 }) {
            let service = c.service()
            let pending = service.beginReplacing(service.text, version: 1)
            let before = pending.snapshot.diagnostics
            guard let after = service.accept(pending.run())?.diagnostics else {
                t.check(false, "\(c.label): the check was dropped")
                continue
            }
            var problems: [String] = []
            for d in before {
                if d.message.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(d.id.rawValue): no message") }
                guard let checked = after.first(where: { $0.id == d.id && $0.range == d.range }) else { continue }
                compared += 1
                if checked.message != d.message { problems.append("\(d.id.rawValue): “\(d.message)” before, “\(checked.message)” after") }
            }
            t.equal(problems, [], c.label)
        }
        print("    \(compared) diagnostics worded alike before and after their check")
    }
}

func runDeskServiceLongLineTests(_ t: TestRunner) {
    t.suite("Desk: service — positions on long lines agree with NSString") {
        // Conversions on lines that are not ASCII walk from a checkpoint (one about every 256 bytes): every offset of
        // long mixed lines, with every kind of line break between them, converts as NSString counts.
        var random = DeskRandom(seed: 0x10_4E)
        let pieces = ["a", "b", " ", "é", "中", "日本", "😀", "👩‍👩‍👧", "𝄞", "\u{FEFF}", "e\u{301}", "\"", "{", "}"]
        var checked = 0
        for round in 0..<6 {
            var text = ""
            for line in 0..<4 {
                for _ in 0..<(300 + random.int(900)) { text += random.pick(pieces) }
                text += ["\n", "\r\n", "\r", ""][(line + round) % 4]
            }
            let index = DeskTextIndex(text)
            let reference = DeskFuzzLines(text)
            let units = Array(text.utf16)
            // The UTF-8 offset at each UTF-16 offset that starts a scalar.
            var utf8At: [Int: Int] = [:]
            var u8 = 0, u16 = 0
            for scalar in text.unicodeScalars {
                utf8At[u16] = u8
                u8 += String(scalar).utf8.count
                u16 += scalar.utf16.count
            }
            utf8At[u16] = u8
            var problems: [String] = []
            for o in 0...units.count {
                let p = index.position(utf16: o)
                let expected = reference.scalarStarts[o] ? o : o - 1
                if p.offset != expected || p.line != reference.lines[expected] || p.column != reference.columns[expected] {
                    problems.append("utf16 \(o) → \(p), expected \(expected) at \(reference.lines[expected]):\(reference.columns[expected])")
                }
                if let b = utf8At[expected] {
                    if index.utf8Offset(ofUTF16: o) != b { problems.append("utf16 \(o) → utf8 \(index.utf8Offset(ofUTF16: o)), expected \(b)") }
                    if index.utf16Offset(ofUTF8: b) != expected { problems.append("utf8 \(b) → utf16 \(index.utf16Offset(ofUTF8: b))") }
                    if index.position(utf8: b) != p { problems.append("utf8 \(b) → \(index.position(utf8: b))") }
                }
                // (The spot between a CR and its LF comes back as the end of its line's content.)
                let insideCRLF = expected > 0 && expected < units.count && units[expected - 1] == 0x0D && units[expected] == 0x0A
                if !insideCRLF, index.position(line: p.line, column: p.column) != p { problems.append("line \(p.line) column \(p.column)") }
                checked += 1
            }
            t.equal(Array(problems.prefix(5)), [], "round \(round)")
        }
        print("    \(checked) offsets of long mixed lines")
    }
}
