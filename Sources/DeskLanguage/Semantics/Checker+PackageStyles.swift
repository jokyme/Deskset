import Foundation

extension Checker {
    /// Recheck the original package syntax in this member's effective option environment.
    /// Never transplant a member receipt onto a package node or resolve an option by name in lowering.
    static func checkedPackageStyles(_ package: CheckedFile, member: CheckedFile,
                                     catalog: DeskCatalog) throws -> CheckedFile {
        // Validate supplied receipts before rechecking; regeneration must not repair forged input.
        let original = Desk.check(package.tree, context: CheckContext(catalog: catalog))
        var pending = package.tree.rootNode.childNodes.filter { $0.kind == .styleDecl }
        while let node = pending.popLast() {
            let identity = package.tree.id(of: node)
            guard package.symbols[identity] == original.symbols[identity],
                  package.types[identity] == original.types[identity],
                  package.canonicalNumericValues[identity] == original.canonicalNumericValues[identity],
                  package.numericCoercions[identity] == original.numericCoercions[identity],
                  package.dependencies[identity] == original.dependencies[identity] else {
                throw DeskCompilationIssue(kind: .invalidCheckedModel, file: package.tree.file,
                                           range: node.textRange, message: "Package style has inconsistent source receipts")
            }
            pending.append(contentsOf: node.childNodes)
        }
        guard package.dataUses == original.dataUses else {
            throw DeskCompilationIssue(kind: .invalidCheckedModel, file: package.tree.file,
                                       range: package.tree.rootNode.textRange, message: "Package style has inconsistent data receipts")
        }
        let memberChecker = Checker(tree: member.tree,
                                    context: CheckContext(catalog: catalog, package: CheckedPackage(file: package)))
        let memberResult = memberChecker.run()
        guard memberResult.options == member.options else {
            throw DeskCompilationIssue(kind: .invalidCheckedModel, file: member.tree.file,
                                       range: member.tree.rootNode.textRange, message: "Member option facts do not match their source")
        }
        let checker = Checker(tree: package.tree, context: CheckContext(catalog: catalog))
        // Export settled facts, not mutable Val.open indices owned by the member checker.
        for (name, option) in memberChecker.options {
            let facts = member.options[name] ?? package.options[name]
            guard let facts else { continue }
            var value = Val(facts.type)
            value.base = facts.displayBase
            let binding = OptionInfo(name: name, control: facts.control, node: option.node,
                                     id: facts.node, nameRange: option.nameRange, file: option.file,
                                     fromPackage: option.fromPackage, val: value)
            binding.wholeCommand = option.wholeCommand
            binding.assignedNonConstant = option.assignedNonConstant
            binding.localEnum = facts.localEnum
            binding.choices = facts.choices
            checker.options[name] = binding
            if let local = facts.localEnum { checker.localEnums[local] = facts.choices }
        }
        for node in package.tree.rootNode.childNodes where node.kind == .styleDecl {
            checker.collectStyle(node)
        }
        // Names resolve in the effective member namespace, while every body keeps its source tree.
        for (name, style) in memberChecker.styles where !style.fromPackage { checker.styles[name] = style }
        for style in checker.styleOrder { checker.checkStyleBody(style) }
        checker.completeNumericMetadata()
        let checked = checker.result(root: nil)
        if let diagnostic = checked.diagnostics.first(where: { $0.severity == .error }) {
            throw DeskCompilationIssue(kind: .invalidCheckedModel, file: diagnostic.file,
                                       range: diagnostic.range, message: "Package style failed member-context checking")
        }
        return checked
    }
}
