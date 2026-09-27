import Foundation
@testable import DeskLanguage

func runDeskSyntaxTests(_ t: TestRunner) {
    t.suite("Desk: acceptance (syntax)") {
        for name in ["CPU", "MonthView"] {
            let url = deskFixtures.appendingPathComponent("Acceptance/\(name).desk")
            let data = try Data(contentsOf: url)
            guard case .text(let text, let file) = Desk.load(data, fileName: "\(name).desk") else {
                t.check(false, "\(name) did not load")
                continue
            }
            let tree = Desk.parse(text, file: file)
            t.equal(tree.description, text, "\(name) round trip")
            t.equal(tree.diagnostics.map(\.description), [], "\(name) diagnostics")
            t.equal(deskTreeProblems(tree), [], name)
            print(tree.root.outline)
        }
    }
}
