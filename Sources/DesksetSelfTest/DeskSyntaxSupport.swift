import Foundation
@testable import DeskLanguage

// Helpers shared by the "Desk: …" syntax suites.

/// The repository root (for fixtures under TestSkins/Desk and the source layering check).
let deskRepositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

let deskFixtures = deskRepositoryRoot.appendingPathComponent("TestSkins/Desk")

func deskParse(_ text: String, file: String = "Test.desk") -> SyntaxTree {
    Desk.parse(text, file: DeskFileID(path: file))
}

/// The ids of a tree's diagnostics, in order.
func deskIDs(_ tree: SyntaxTree) -> [String] { tree.diagnostics.map(\.id.rawValue) }

/// Only the errors' ids.
func deskErrorIDs(_ tree: SyntaxTree) -> [String] {
    tree.diagnostics.filter { $0.severity == .error }.map(\.id.rawValue)
}

/// Every fixture file under TestSkins/Desk with its text (sorted by path).
func deskFixtureFiles(_ subfolder: String? = nil) -> [(path: String, text: String)] {
    let root = subfolder.map { deskFixtures.appendingPathComponent($0) } ?? deskFixtures
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var files: [(String, String)] = []
    for case let url as URL in enumerator where url.pathExtension == "desk" {
        guard let data = try? Data(contentsOf: url) else { continue }
        let relative = url.path.replacingOccurrences(of: deskFixtures.path + "/", with: "")
        files.append((relative, String(decoding: data, as: UTF8.self)))
    }
    return files.sorted { $0.0 < $1.0 }
}

/// The tree invariants of §9.2: the printed tree is the text; token lengths add up to the text length; every
/// missing token is empty and has no trivia; no trivia holds a non-trivia character; nodes' lengths add up.
func deskTreeProblems(_ tree: SyntaxTree) -> [String] {
    var problems: [String] = []
    if tree.description != tree.text { problems.append("round trip differs") }
    var total = 0
    var stack: [SyntaxNode] = [tree.root]
    while let node = stack.popLast() {
        var sum = 0
        for child in node.children {
            switch child {
            case .node(let n):
                sum += n.byteLength
                stack.append(n)
            case .token(let t):
                sum += t.utf8Length
                total += t.utf8Length
                if t.isMissing && (!t.text.isEmpty || !t.leadingTrivia.isEmpty || !t.trailingTrivia.isEmpty) {
                    problems.append("missing token \(t.kind) has text or trivia")
                }
                for piece in t.leadingTrivia + t.trailingTrivia {
                    if let bad = deskTriviaProblem(piece) { problems.append(bad) }
                }
            }
        }
        if sum != node.byteLength { problems.append("\(node.kind) length \(node.byteLength) != children \(sum)") }
    }
    if total != tree.text.utf8.count { problems.append("tokens \(total) bytes, text \(tree.text.utf8.count)") }
    if tree.root.children.last?.token?.kind != .eof { problems.append("the last child is not eof") }
    return problems
}

func deskTriviaProblem(_ piece: Trivia) -> String? {
    switch piece {
    case .spaces(let n): return n > 0 ? nil : "empty spaces"
    case .tabs(let n): return n > 0 ? nil : "empty tabs"
    case .newline: return nil
    case .lineComment(let s):
        if !s.utf8.starts(with: "//".utf8) || s.utf8.contains(0x0A) || s.utf8.contains(0x0D) {
            return "bad line comment \(s.debugDescription)"
        }
    case .blockComment(let s):
        if !s.utf8.starts(with: "/*".utf8) { return "bad block comment \(s.debugDescription)" }
    case .unusualSpace(let s):
        if s.isEmpty || !s.unicodeScalars.allSatisfy({ $0.value > 0x7F }) { return "bad unusual space" }
    case .invisible(let s):
        if s.isEmpty || !s.unicodeScalars.allSatisfy({ $0.value > 0x7F }) { return "bad invisible" }
    case .byteOrderMark: return nil
    }
    return nil
}

/// The shape of a tree's diagnostics: ranges inside the text on character boundaries; fix-it title and note keys the
/// catalog knows (`SyntaxMessageKeys`); edits in the same file, inside the text, on character boundaries and not
/// overlapping; the only fix-it without edits is "Jump to line", with its line.
func deskDiagnosticProblems(_ tree: SyntaxTree) -> [String] {
    let bytes = Array(tree.text.utf8)
    func boundary(_ offset: Int) -> Bool {
        offset >= 0 && offset <= bytes.count && (offset == bytes.count || bytes[offset] & 0xC0 != 0x80)
    }
    let titles = Set(SyntaxMessageKeys.fixItTitles)
    let notes = Set(SyntaxMessageKeys.notes)
    var problems: [String] = []
    for d in tree.diagnostics {
        let name = d.id.rawValue
        if d.file != tree.file { problems.append("\(name) in another file") }
        if !boundary(d.range.lowerBound) || !boundary(d.range.upperBound) { problems.append("\(name) range \(d.range)") }
        for note in d.notes where !notes.contains(note.messageKey) { problems.append("\(name) note \(note.messageKey)") }
        for fixIt in d.fixIts {
            if !titles.contains(fixIt.titleKey) { problems.append("\(name) fix-it title \(fixIt.titleKey)") }
            if fixIt.edits.isEmpty {
                if fixIt.titleKey != "jumpToLine" || fixIt.titleArguments["line"] == nil {
                    problems.append("\(name) \(fixIt.titleKey) has no edits")
                }
                continue
            }
            let edits = fixIt.edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
            var end = 0
            for edit in edits {
                if edit.file != tree.file { problems.append("\(name) edit in another file") }
                if !boundary(edit.range.lowerBound) || !boundary(edit.range.upperBound) {
                    problems.append("\(name) \(fixIt.titleKey) edit \(edit.range)")
                }
                if edit.range.lowerBound < end { problems.append("\(name) \(fixIt.titleKey) edits overlap") }
                end = max(end, edit.range.upperBound)
            }
        }
    }
    return problems
}

/// Applies a fix-it's edits to a text.
func deskApply(_ fixIt: FixIt, to text: String) -> String { TextEdit.apply(fixIt.edits, to: text) }

/// A deterministic generator for fuzzing and generated corpora (seeded, printed on failure).
struct DeskRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
    mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
}

/// The tokens formatting must keep (F12), in order: every non-trivia token, except the `;` and `,` separators of
/// blocks (which may become line breaks) and a language group's `:` (removed); a translation entry's `=` reads as `:`.
func deskSignificantTokens(_ tree: SyntaxTree) -> [String] {
    var out: [String] = []
    var stack: [(node: SyntaxNode, next: Int)] = [(tree.root, 0)]
    while !stack.isEmpty {
        let (node, next) = stack[stack.count - 1]
        guard next < node.children.count else { stack.removeLast(); continue }
        stack[stack.count - 1].next += 1
        switch node.children[next] {
        case .node(let child):
            stack.append((child, 0))
        case .token(let t):
            if t.isMissing || t.kind == .eof { continue }
            if (node.kind == .block || node.kind == .sourceFile) && (t.kind == .semicolon || t.kind == .comma) { continue }
            if node.kind == .group && t.kind == .colon { continue }
            if node.kind == .entry && t.kind == .equal { out.append("colon::"); continue }
            out.append("\(t.kind.rawValue):\(t.text)")
        }
    }
    return out
}
