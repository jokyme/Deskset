import Foundation
@testable import DeskLanguage

/// Temporary exploration harness: DESK_SCRATCH=path prints each snippet's outline and diagnostics (snippets are
/// separated by lines of `----`).
func runDeskScratch(_ t: TestRunner) {
    guard let path = ProcessInfo.processInfo.environment["DESK_SCRATCH"],
          let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    t.suite("Desk: scratch") {
        for snippet in text.components(separatedBy: "\n----\n") {
            let tree = deskParse(snippet)
            print("=== " + snippet.replacingOccurrences(of: "\n", with: "⏎"))
            print("    " + tree.root.outline)
            for d in tree.diagnostics {
                let loc = tree.location(of: d.range.lowerBound)
                let fixes = d.fixIts.map { f in "\(f.titleKey){" + f.edits.map { "\($0.range)→\($0.replacement.debugDescription)" }.joined(separator: ",") + "}" }
                print("    \(d.id.rawValue) \(d.severity) \(loc) \(d.arguments.keys.sorted().map { "\($0)=\(d.arguments[$0]!)" }.joined(separator: " ")) \(fixes.joined(separator: " "))")
            }
            let problems = deskTreeProblems(tree)
            if !problems.isEmpty { print("    PROBLEMS: \(problems)") }
        }
    }
}
