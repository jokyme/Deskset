import Foundation
@testable import DeskLanguage

// Helpers shared by the "Desk: checker …" and "Desk: diagnostics" suites.

func deskCheck(_ text: String, file: String = "Test.desk", context: CheckContext = CheckContext()) -> CheckedFile {
    Desk.check(Desk.parse(text, file: DeskFileID(path: file)), context: context)
}

/// `DK3001@2:14` for every diagnostic, in order.
func deskDiagnosticSummary(_ checked: CheckedFile) -> [String] {
    checked.diagnostics.map { d in
        let location = checked.tree.location(of: d.range.lowerBound)
        return "\(d.id.rawValue)@\(location.line):\(location.column)"
    }
}

/// One line per diagnostic: id, severity, position, both messages and the fix-it titles.
func deskDescribe(_ checked: CheckedFile, catalog: DeskCatalog = .current) -> String {
    var lines: [String] = []
    for d in checked.diagnostics {
        let location = checked.tree.location(of: d.range.lowerBound)
        let fixes = d.fixIts.map { f -> String in
            let title = f.title(in: .english, catalog: catalog)
            let applied = TextEdit.apply(f.edits.filter { $0.file == checked.tree.file }, to: checked.tree.text)
            return "[\(title)] → \(applied.debugDescription)"
        }
        lines.append("\(d.id.rawValue) \(d.severity) \(location): \(d.message(in: .english, catalog: catalog))")
        lines.append("    zh: \(d.message(in: .simplifiedChinese, catalog: catalog))")
        for f in fixes { lines.append("    fix " + f) }
    }
    return lines.joined(separator: "\n")
}

/// `DESK_CHECK=file`: checks each snippet of the file (separated by lines of `----`) and prints the diagnostics with
/// their messages in both languages and each fix-it applied.
func runDeskCheckScratch(_ t: TestRunner) {
    guard let path = ProcessInfo.processInfo.environment["DESK_CHECK"],
          let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    t.suite("Desk: check scratch") {
        for snippet in text.components(separatedBy: "\n----\n") {
            let start = ProcessInfo.processInfo.systemUptime
            let checked = deskCheck(snippet)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            print("=== " + snippet.replacingOccurrences(of: "\n", with: "⏎") + String(format: "   (%.1f ms)", ms))
            print(deskDescribe(checked))
            if ProcessInfo.processInfo.environment["DESK_CHECK_ARGUMENTS"] != nil {
                for d in checked.diagnostics { print("    \(d.id.rawValue) arguments: \(d.arguments)") }
            }
        }
    }
}
