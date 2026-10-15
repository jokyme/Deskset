import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum SharedOptionCompilationFixtureError: Error { case receipt }

/// Baseline uses only the existing API. Executable package options should replace the explicit unsupported gate.
func runDeskSharedOptionsCompilationTests(_ t: TestRunner) {
    func package(_ source: String) -> CheckedFile {
        let checked = deskCheck(source, file: "package.desk")
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        return checked
    }
    func widget(_ source: String, file: String, package: CheckedFile) -> CheckedFile {
        deskCheck(source, file: file, context: CheckContext(package: CheckedPackage(file: package)))
    }
    func optionReads(_ checked: CheckedFile, name: String) -> [NodeID] {
        var pending = [checked.tree.rootNode], result: [NodeID] = []
        while let node = pending.popLast() {
            if let member = MemberExprSyntax(node), member.name.token.name == name,
               IdentifierExprSyntax(member.base.node)?.name == "options" {
                result.append(checked.tree.id(of: node))
            }
            pending.append(contentsOf: node.childNodes)
        }
        return result
    }
    func compile(_ checked: CheckedFile, package: CheckedFile) -> WidgetProgram? {
        let result = Desk.compile(checked, package: package)
        t.check(result.issues.isEmpty, "\(checked.tree.file.path): \(result.issues)")
        t.check(result.program != nil, "a checked package option must have an executable program")
        t.equal(result.diagnostics, checked.diagnostics + package.diagnostics)
        return result.program
    }

    t.suite("Desk: shared options compilation: two members read the same checked package Toggle definition") {
        let shared = package(#"""
            package { name: "Shared toggles" }
            options { compact = Toggle("Shared compact", default: true) }
            """#)
        guard let facts = shared.options["compact"] else { throw SharedOptionCompilationFixtureError.receipt }
        t.equal(facts.scope, .package); t.equal(facts.type, .bool)
        let sources = [
            ("First.desk", #"info { name: "First" }"# + "\n" + #"widget { Text(options.compact).size(80, 20) }"#, "Yes"),
            ("Second.desk", #"info { name: "Second" }"# + "\n" + #"widget { Text(options.compact ? "Compact" : "Expanded").size(80, 20) }"#, "Compact")
        ]
        for (file, source, expected) in sources {
            let checked = widget(source, file: file, package: shared)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(checked.options.isEmpty, "the checked widget exposes own declarations, not a fabricated merged table")
            let reads = optionReads(checked, name: "compact")
            t.equal(reads.count, 1)
            for id in reads { t.equal(checked.symbols[id], .option(facts.node, file: shared.tree.file)) }
            if let program = compile(checked, package: shared) {
                let definitions = deskOptionDefinitions(program.options)
                t.equal(definitions.count, 1); t.equal(definitions.first?.name, "compact")
                t.equal(definitions.first?.defaultValue, .boolean(true))
                t.equal(definitions.first?.title, .string("Shared compact"))
                var runtime = try ProgramRuntime(program: program)
                let scene = try runtime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)
                t.equal(deskOptionTexts(scene), [expected])
                t.equal(runtime.optionValues.values, ["compact": .boolean(true)])
            }
        }
    }

    t.suite("Desk: shared options compilation: a local override retains its own label default and declaration identity") {
        let shared = package(#"""
            package { name: "Shared toggles" }
            options { compact = Toggle("Shared compact", default: true) }
            """#)
        let source = #"""
            info { name: "Local override" }
            options { compact = Toggle("Local compact", default: false) }
            widget { Text(options.compact).size(80, 20) }
            """#
        let checked = widget(source, file: "Override.desk", package: shared)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        t.check(checked.diagnostics.contains { $0.id == .optionReplacesPackage })
        guard let own = checked.options["compact"], let inherited = shared.options["compact"] else {
            throw SharedOptionCompilationFixtureError.receipt
        }
        t.equal(own.scope, .widget); t.equal(own.type, inherited.type)
        t.check(own.node != inherited.node)
        let reads = optionReads(checked, name: "compact")
        t.equal(reads.count, 1)
        for id in reads { t.equal(checked.symbols[id], .option(own.node, file: checked.tree.file)) }
        if let program = compile(checked, package: shared) {
            let definitions = deskOptionDefinitions(program.options)
            t.equal(definitions.count, 1)
            t.equal(definitions.first?.title, .string("Local compact"))
            t.equal(definitions.first?.defaultValue, .boolean(false))
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)
            t.equal(deskOptionTexts(scene), ["No"])
            t.equal(runtime.optionValues.values, ["compact": .boolean(false)])
        }
        t.equal(inherited.defaultText, "true", "a widget override does not mutate the package's authoritative definition")
    }

    t.suite("Desk: shared options compilation: D99 rejects different local enum choices despite the same nominal name") {
        let shared = package(#"""
            package { name: "Shared modes" }
            options { mode = Picker("Package mode", [.dayMode, .nightMode], default: .dayMode) }
            """#)
        let source = #"""
            info { name: "Invalid override" }
            options { mode = Picker("Local mode", [.dayMode, .quietMode], default: .dayMode) }
            widget { Text(options.mode) }
            """#
        let checked = widget(source, file: "InvalidOverride.desk", package: shared)
        guard let own = checked.options["mode"], let inherited = shared.options["mode"] else {
            throw SharedOptionCompilationFixtureError.receipt
        }
        t.check(own.localEnum != nil && inherited.localEnum != nil)
        t.equal(own.type, inherited.type, "same generated type name alone cannot prove D99 replacement compatibility")
        t.equal(inherited.choices, ["dayMode", "nightMode"])
        t.equal(own.choices, ["dayMode", "quietMode"])
        let errors = checked.diagnostics(.error)
        t.check(errors.contains { $0.id == .replacedOptionTypeDiffers }, deskDescribe(checked))
        if let mismatch = errors.first(where: { $0.id == .replacedOptionTypeDiffers }) {
            t.equal(mismatch.file, checked.tree.file)
            t.check(mismatch.notes.contains { $0.file == shared.tree.file }, "D99 points to both real declarations")
        }
        let result = Desk.compile(checked, package: shared)
        t.check(result.program == nil); t.check(result.elementRefs.isEmpty)
    }
}
