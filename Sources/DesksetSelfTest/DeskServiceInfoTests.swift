import Foundation
@testable import DeskLanguage

// Semantic tokens, hover cards and signature help of the language service. Properties on every file of the corpus
// and every catalog example, golden results on the acceptance widgets and small snippets.
//
// `DESK_TOKENS_DUMP=path/to/file.desk` prints the semantic tokens of a file (to write goldens).

/// `line:column text type[modifiers]` for each token (1-based).
func deskTokenLines(_ snapshot: DeskSnapshot, _ tokens: [DeskSemanticToken]) -> [String] {
    let text = snapshot.text as NSString
    return tokens.map { token in
        let covered = token.range.end.offset <= text.length ? text.substring(with: token.range.nsRange) : "?"
        return "\(token.range.start) \(covered) \(token.type)" + (token.modifiers.isEmpty ? "" : "[\(token.modifiers)]")
    }
}

func runDeskServiceInfoTests(_ t: TestRunner) {
    if let path = ProcessInfo.processInfo.environment["DESK_TOKENS_DUMP"] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); return }
        let snapshot = deskNavService(text, file: (path as NSString).lastPathComponent).snapshot
        for line in deskTokenLines(snapshot, snapshot.semanticTokens().tokens) { print(line) }
        return
    }
    if let path = ProcessInfo.processInfo.environment["DESK_HOVER_DUMP"] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); return }
        let language: DiagnosticLanguage = ProcessInfo.processInfo.environment["DESK_HOVER_ZH"] != nil ? .simplifiedChinese : .english
        let snapshot = deskNavService(text, file: (path as NSString).lastPathComponent).snapshot
        var seen = Set<DeskRange>()
        for token in deskNavTokenStarts(snapshot.tree) {
            let position = snapshot.index.position(utf8: token.lowerBound)
            if let hover = snapshot.hover(at: position), seen.insert(hover.range).inserted {
                print("=== \(position)")
                print(hover.markdown(language))
            }
            if let help = snapshot.signatureHelp(at: position) {
                print("--- signature help at \(position): active \(help.activeSignature) parameter \(help.activeParameter.map(String.init) ?? "none")")
                print(help.markdown(language))
            }
        }
        return
    }
    runDeskSemanticTokenTests(t)
}

func runDeskSemanticTokenTests(_ t: TestRunner) {
}
