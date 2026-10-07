import Foundation
@testable import DeskLanguage

private enum StyleReceiptFixtureError: Error { case missing }

func runDeskStyleReceiptTests(_ t: TestRunner) {
    func package(_ source: String) -> CheckedFile {
        let result = deskCheck(source, file: "package.desk")
        t.check(result.diagnostics(.error).isEmpty, deskDescribe(result))
        return result
    }
    func widget(_ source: String, package: CheckedFile? = nil) -> CheckedFile {
        let result = deskCheck(source, file: "Widget.desk", context: CheckContext(package: package.map(CheckedPackage.init(file:))))
        t.check(result.diagnostics(.error).isEmpty, deskDescribe(result))
        return result
    }
    func facts(_ checked: CheckedFile) throws -> ElementFacts {
        guard let result = checked.elements.values.first(where: { $0.component == "Text" }) else { throw StyleReceiptFixtureError.missing }
        return result
    }
    func modifier(_ checked: CheckedFile, style: String, name: String) throws -> ModifierAppSyntax {
        guard let id = checked.styles[style], let node = checked.tree.resolve(id), let declaration = StyleDeclSyntax(node),
              let result = declaration.block.statements.compactMap(ModifierStmtSyntax.init).flatMap(\.modifiers)
                .first(where: { $0.name.token.text == name }) else { throw StyleReceiptFixtureError.missing }
        return result
    }
    func ownModifier(_ checked: CheckedFile, name: String) throws -> ModifierAppSyntax {
        guard let (id, _) = checked.elements.first(where: { $0.value.component == "Text" }),
              let node = checked.tree.resolve(id), let call = CallStmtSyntax(node),
              let result = call.modifiers.first(where: { $0.name.token.text == name }) else { throw StyleReceiptFixtureError.missing }
        return result
    }
    func argument(_ modifier: ModifierAppSyntax, label: String? = nil) throws -> PositionedNode {
        guard let result = modifier.arguments?.arguments.first(where: { $0.label?.name == label })?.value.node else {
            throw StyleReceiptFixtureError.missing
        }
        return result
    }
    func candidate(_ checked: CheckedFile, facet: FacetID, at index: Int = 0) throws -> Candidate {
        guard let values = try facts(checked).facets[facet], values.indices.contains(index) else { throw StyleReceiptFixtureError.missing }
        return values[index]
    }
    func receipt(_ candidate: Candidate, source: CheckedFile, style: String, modifier expected: ModifierAppSyntax,
                 value: PositionedNode, fixed: String? = nil, other: SyntaxTree? = nil) {
        let origin = source.tree.id(of: expected.node)
        t.equal(candidate.origin, .style(style, origin, file: source.tree.file))
        t.equal(candidate.value, source.tree.id(of: value))
        t.equal(candidate.fixedValue, fixed)
        t.equal(candidate.level, 2)
        t.check(candidate.hard)
        guard case .style(_, let actualOrigin, let file) = candidate.origin else { t.check(false); return }
        t.equal(file, source.tree.file)
        t.check(source.tree.resolve(actualOrigin)?.node === expected.node.node,
                "origin resolves the exact source modifier, not a node reconstructed from its offset")
        t.check(source.tree.resolve(candidate.value)?.node === value.node,
                "value resolves its own source expression independently from the modifier")
        if let other {
            t.check(other.resolve(actualOrigin) == nil, "a different tree cannot accept this origin")
            t.check(other.resolve(candidate.value) == nil, "a different tree cannot accept this value")
        }
    }

    t.suite("Desk: style receipts: local modifiers preserve expression fixed value and own origins") {
        let checked = widget(#"info { name: "Local" }"# + "\n" +
            #"widget { Text("A").style(local).font(19) }"# + "\n" +
            #"style local { .color(.red).font(17).italic() }"#)
        let color = try modifier(checked, style: "local", name: "color")
        let font = try modifier(checked, style: "local", name: "font")
        let italic = try modifier(checked, style: "local", name: "italic")
        let colorCandidate = try candidate(checked, facet: "color")
        receipt(colorCandidate, source: checked, style: "local", modifier: color, value: try argument(color))
        t.equal(colorCandidate.position, 1); t.equal(colorCandidate.condition, nil)
        let size = try candidate(checked, facet: "font.size", at: 1)
        receipt(size, source: checked, style: "local", modifier: font, value: try argument(font))
        t.equal(size.position, 2)
        let italicCandidate = try candidate(checked, facet: "font.italic")
        receipt(italicCandidate, source: checked, style: "local", modifier: italic, value: italic.node, fixed: "true")
        t.equal(italicCandidate.position, 3)
        let own = try ownModifier(checked, name: "font"), ownCandidate = try candidate(checked, facet: "font.size")
        t.equal(ownCandidate.origin, .own(checked.tree.id(of: own.node)))
        t.equal(ownCandidate.value, checked.tree.id(of: try argument(own)))
        t.equal(ownCandidate.position, 4); t.equal(ownCandidate.level, 3)
        t.equal(checked.canonicalNumericValues[size.value], 17)
        t.equal(checked.canonicalNumericValues[ownCandidate.value], 19)
    }

    t.suite("Desk: style receipts: package origins survive colliding offsets and same text reparses") {
        let packageSource = "style base { .color(.red) }\n"
        let widgetSource = #"style ownn { .color(.blue) }"# + "\n" +
            #"info { name: "Collision" }"# + "\n" + #"widget { Text("A").style(base).style(ownn) }"#
        let shared = package(packageSource), checked = widget(widgetSource, package: shared)
        let packageColor = try modifier(shared, style: "base", name: "color")
        let ownColor = try modifier(checked, style: "ownn", name: "color")
        t.equal(packageColor.node.textRange.lowerBound, ownColor.node.textRange.lowerBound,
                "fixture deliberately places different modifiers at the same file offset")
        t.check(shared.tree.version != checked.tree.version)
        let packageCandidate = try candidate(checked, facet: "color", at: 1)
        receipt(packageCandidate, source: shared, style: "base", modifier: packageColor,
                value: try argument(packageColor), other: checked.tree)
        receipt(try candidate(checked, facet: "color"), source: checked, style: "ownn", modifier: ownColor,
                value: try argument(ownColor), other: shared.tree)
        t.equal(packageCandidate.position, 1)
        let reparsed = package(packageSource)
        let next = widget(widgetSource, package: reparsed)
        let nextColor = try modifier(reparsed, style: "base", name: "color")
        let nextCandidate = try candidate(next, facet: "color", at: 1)
        receipt(nextCandidate, source: reparsed, style: "base", modifier: nextColor,
                value: try argument(nextColor), other: shared.tree)
        t.check(nextCandidate.value != packageCandidate.value)
        if case .style(_, let oldOrigin, _) = packageCandidate.origin {
            t.check(reparsed.tree.resolve(oldOrigin) == nil, "unchanged source text does not qualify an old parse identity")
        } else { t.check(false) }
    }

    t.suite("Desk: style receipts: nested package and local styles expand includes before own modifiers") {
        let shared = package(#"style base { .color(.red) }"# + "\n" + #"style middle { .color(.green).style(base) }"#)
        let checked = widget(#"info { name: "Nested" }"# + "\n" + #"widget { Text("A").style(outer) }"# + "\n" +
            #"style outer { .color(.blue).style(middle) }"#, package: shared)
        let colors = try facts(checked).facets["color"] ?? []
        t.equal(colors.count, 3); t.equal(colors.map(\.position), [3, 2, 1])
        for (index, source, style) in [(0, checked, "outer"), (1, shared, "middle"), (2, shared, "base")] {
            let color = try modifier(source, style: style, name: "color")
            receipt(try candidate(checked, facet: "color", at: index), source: source, style: style,
                    modifier: color, value: try argument(color), other: source.tree.version == checked.tree.version ? shared.tree : checked.tree)
        }
        t.check(colors.allSatisfy { $0.condition == nil })
    }

    t.suite("Desk: style receipts: widget replacement is used inside package includes with its own source identity") {
        let shared = package(#"style base { .color(.red) }"# + "\n" + #"style card { .style(base).font(16) }"#)
        let checked = widget(#"info { name: "Replacement" }"# + "\n" + #"widget { Text("A").style(card) }"# + "\n" +
            #"style base { .color(.blue).italic() }"#, package: shared)
        t.check(checked.diagnostics.contains { $0.id.rawValue == "DK3027" })
        let localColor = try modifier(checked, style: "base", name: "color")
        let italic = try modifier(checked, style: "base", name: "italic")
        let cardFont = try modifier(shared, style: "card", name: "font")
        receipt(try candidate(checked, facet: "color"), source: checked, style: "base", modifier: localColor,
                value: try argument(localColor), other: shared.tree)
        receipt(try candidate(checked, facet: "font.italic"), source: checked, style: "base", modifier: italic,
                value: italic.node, fixed: "true", other: shared.tree)
        receipt(try candidate(checked, facet: "font.size"), source: shared, style: "card", modifier: cardFont,
                value: try argument(cardFont), other: checked.tree)
        t.equal(try facts(checked).facets["color"]?.count, 1)
        t.equal(try candidate(checked, facet: "color").position, 1)
        t.equal(try candidate(checked, facet: "font.italic").position, 2)
        t.equal(try candidate(checked, facet: "font.size").position, 3)
        let oldColor = try modifier(shared, style: "base", name: "color")
        t.check(try candidate(checked, facet: "color").value != shared.tree.id(of: try argument(oldColor)))
    }

    t.suite("Desk: style receipts: repeated applications retain source IDs and distinct expansion positions") {
        let shared = package(#"style base { .color(.red) }"#)
        let checked = widget(#"info { name: "Repeated" }"# + "\n" +
            #"widget { Text("A").style(wrapped).style(base).style(wrapped).color(.blue) }"# + "\n" +
            #"style wrapped { .style(base).font(16) }"#, package: shared)
        let colors = try facts(checked).facets["color"] ?? []
        t.equal(colors.map(\.position), [6, 4, 3, 1]); t.equal(colors.map(\.level), [3, 2, 2, 2])
        let packageColor = try modifier(shared, style: "base", name: "color")
        for candidate in colors.dropFirst() {
            receipt(candidate, source: shared, style: "base", modifier: packageColor,
                    value: try argument(packageColor), other: checked.tree)
        }
        t.equal(Set(colors.dropFirst().map(\.origin)).count, 1)
        t.equal(Set(colors.dropFirst().map(\.value)).count, 1)
        let fonts = try facts(checked).facets["font.size"] ?? []
        t.equal(fonts.map(\.position), [5, 2])
        let font = try modifier(checked, style: "wrapped", name: "font")
        for candidate in fonts { receipt(candidate, source: checked, style: "wrapped", modifier: font, value: try argument(font)) }
        let duplicatedInclude = widget(#"info { name: "Includes" }"# + "\n" + #"widget { Text("A").style(twice) }"# + "\n" +
            #"style twice { .style(base).style(base) }"#, package: shared)
        let duplicateColors = try facts(duplicatedInclude).facets["color"] ?? []
        t.equal(duplicateColors.map(\.position), [2, 1])
        for candidate in duplicateColors {
            receipt(candidate, source: shared, style: "base", modifier: packageColor,
                    value: try argument(packageColor), other: duplicatedInclude.tree)
        }
    }

    t.suite("Desk: style receipts: source and application conditions retain their original trees and order") {
        let shared = package(#"style alert { .color(.red, if: cpu.usage > 50%) }"#)
        let checked = widget(#"info { name: "Conditions" }"# + "\n" +
            #"widget { Text("A").style(alert, if: battery.charging).color(.blue) }"#, package: shared)
        let color = try modifier(shared, style: "alert", name: "color")
        let application = try ownModifier(checked, name: "style")
        let sourceCondition = try argument(color, label: "if")
        let applicationCondition = try argument(application, label: "if")
        let selected = try candidate(checked, facet: "color")
        receipt(selected, source: shared, style: "alert", modifier: color, value: try argument(color), other: checked.tree)
        let ownID = checked.tree.id(of: applicationCondition), sourceID = shared.tree.id(of: sourceCondition)
        t.equal(selected.condition, .all([.expr(ownID), .expr(sourceID)]))
        t.check(checked.tree.resolve(ownID)?.node === applicationCondition.node)
        t.check(shared.tree.resolve(sourceID)?.node === sourceCondition.node)
        t.check(shared.tree.resolve(ownID) == nil); t.check(checked.tree.resolve(sourceID) == nil)
        t.equal(selected.position, 1)
        let own = try candidate(checked, facet: "color", at: 1)
        t.equal(own.level, 3); t.equal(own.position, 2); t.equal(own.condition, nil)
        t.check(selected.sortKey > own.sortKey, "the identity repair does not alter conditional precedence")
    }
}
