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
            t.equal(deskTreeProblems(tree) + deskDiagnosticProblems(tree), [], name)
            t.equal(Desk.format(tree), [], "\(name) is in canonical style")
        }
    }

    t.suite("Desk: syntax fixtures") {
        // Valid fixtures parse with no syntax diagnostics and are in canonical style; invalid ones round-trip.
        for (name, expectClean) in [("Syntax/all-productions.desk", true), ("Syntax/package.desk", true),
                                    ("Syntax/crlf-tabs.desk", false), ("Syntax/bom-no-final-newline.desk", false),
                                    ("Syntax/errors.desk", false), ("Syntax/foreign.desk", false)] {
            let data = try Data(contentsOf: deskFixtures.appendingPathComponent(name))
            guard case .text(let text, let file) = Desk.load(data, fileName: name) else {
                t.check(false, "\(name) did not load")
                continue
            }
            let tree = Desk.parse(text, file: file)
            t.equal(deskTreeProblems(tree) + deskDiagnosticProblems(tree), [], name)
            if expectClean {
                t.equal(tree.diagnostics.map(\.description), [], name)
                t.equal(Desk.format(tree).map(\.description), [], "\(name) is in canonical style")
            }
        }
        // One diagnostic per broken construct; what only the checker can know (`.colour`, `cpuu`) is not reported here.
        let errors = deskParse(try String(contentsOf: deskFixtures.appendingPathComponent("Syntax/errors.desk"), encoding: .utf8))
        t.equal(deskIDs(errors), ["DK1001", "DK9001", "DK2006", "DK9004", "DK9006", "DK1021", "DK7004", "DK1014", "DK1013"])
        let foreign = deskParse(try String(contentsOf: deskFixtures.appendingPathComponent("Syntax/foreign.desk"), encoding: .utf8))
        t.equal(deskIDs(foreign), ["DK9105", "DK9302", "DK9201", "DK9104", "DK9202", "DK9014"])
        t.equal(foreign.root.allNodes(.foreignConstruct).count, 6, "each pasted run is one node")
        t.check(foreign.root.allNodes(.callStmt).contains { $0.trimmedText == "Text(\"still parsed\")" },
                "the Desk code after the foreign lines is parsed")
        let productions = deskParse(try String(contentsOf: deskFixtures.appendingPathComponent("Syntax/all-productions.desk"),
                                               encoding: .utf8))
        for kind: SyntaxKind in [.infoBlock, .optionsBlock, .widgetBlock, .styleDecl, .translationsBlock, .componentDecl,
                                 .parameterClause, .parameter, .scriptBlock, .block, .declaration, .ifStmt, .elseClause,
                                 .forStmt, .field, .entry, .group, .optionDecl, .assignment, .target, .callStmt, .callee,
                                 .modifierStmt, .modifierApp, .argumentClause, .argument, .label, .ternaryExpr, .binaryExpr,
                                 .prefixExpr, .memberExpr, .callExpr, .implicitMemberExpr, .identifierExpr, .numberLiteral,
                                 .stringLiteral, .stringText, .interpolation, .formatOption, .listLiteral, .parenExpr] {
            t.check(productions.root.firstNode(kind) != nil, "all-productions has a \(kind)")
        }
    }
}
