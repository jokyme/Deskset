import Foundation
import DesksetCore

/// Translation source is checked once; translated placeholders never become executable expressions.
struct ProgramTranslationCompiler {
    private let sources: [Int: CheckedFile]
    private let catalog: DeskCatalog
    private let entries: [NodeID: StringEntry]
    private let patterns: [String: [String: [ProgramTranslationPart]]]
    private var source: [String: [ProgramTranslationPart]] = [:]

    init(checked: CheckedFile, package: CheckedFile?, catalog: DeskCatalog) throws {
        self.catalog = catalog
        if let package, !DeskPackagePath.isPackageFile(package.tree.file.path) {
            throw Self.issue(package, package.tree.rootNode, "Shared translations require a checked package.desk")
        }
        var sources = [checked.tree.version: checked]
        if let package {
            guard sources[package.tree.version] == nil else {
                throw Self.issue(package, package.tree.rootNode, "Shared source tree versions must be distinct")
            }
            sources[package.tree.version] = package
        }
        self.sources = sources
        var entries: [NodeID: StringEntry] = [:]
        for checked in (package.map { [$0, checked] } ?? [checked]) {
            for entry in checked.stringTable {
                guard entries[entry.node] == nil,
                      let node = checked.tree.resolve(entry.node), let string = StringLiteralSyntax(node),
                      !string.isRaw, !string.isTripleQuoted, entry.range == node.textRange,
                      checked.types[entry.node]?.type == .string, !entry.key.isEmpty,
                      entry.key == DeskTranslationKeys.key(of: string, in: checked.tree) else {
                    throw Self.issue(checked, checked.tree.resolve(entry.node) ?? checked.tree.rootNode,
                                     "String table entry has no matching checked literal")
                }
                entries[entry.node] = entry
            }
        }
        self.entries = entries
        var patterns = try package.map { try Self.tables($0, catalog: catalog) } ?? [:]
        for (language, table) in try Self.tables(checked, catalog: catalog) {
            patterns[language, default: [:]].merge(table) { _, own in own }
        }
        self.patterns = patterns
    }

    var translations: ProgramTranslations {
        ProgramTranslations(source: source, languages: patterns.mapValues { table in
            table.filter { source[$0.key] != nil }
        })
    }

    /// Only a checked literal reaching a supported translatable parameter can emit a localized expression.
    mutating func key(for string: StringLiteralSyntax, in checked: CheckedFile, allowed: Bool) throws -> String? {
        guard sources[checked.tree.version]?.tree.file == checked.tree.file else {
            throw Self.issue(checked, string.node, "Translated literal belongs to an unsupplied checked source")
        }
        let identity = checked.tree.id(of: string.node)
        guard let entry = entries[identity] else {
            if allowed, !string.isRaw, !string.isTripleQuoted,
               !DeskTranslationKeys.key(of: string, in: checked.tree).isEmpty {
                throw Self.issue(checked, string.node, "Display literal has no checked translatable string entry")
            }
            return nil
        }
        if !entry.translatable {
            guard !allowed else { throw Self.issue(checked, string.node, "Display literal has a nontranslatable receipt") }
            return nil // The checked model also permits a literal marked as stored before display.
        }
        guard allowed else {
            throw Self.issue(checked, string.node, "A nontranslatable expression cannot own a string table entry")
        }
        guard patterns.values.contains(where: { $0[entry.key] != nil }) else { return nil }
        let parts = try Self.pattern(string, original: Self.placeholders(string), checked: checked, catalog: catalog)
        if let previous = source[entry.key], previous != parts {
            throw Self.issue(checked, string.node, "One translation key has conflicting source patterns")
        }
        source[entry.key] = parts
        return entry.key
    }

    private static func tables(_ checked: CheckedFile, catalog: DeskCatalog) throws -> [String: [String: [ProgramTranslationPart]]] {
        var written: [String: [String: String]] = [:]
        var patterns: [String: [String: [ProgramTranslationPart]]] = [:]
        var count = 0
        let blocks = checked.tree.rootNode.childNodes.filter { $0.kind == .translationsBlock }
        guard blocks.count <= 1 else { throw issue(checked, checked.tree.rootNode, "Duplicate translation blocks") }
        for node in blocks {
            guard let block = TopLevelBlockSyntax(node) else { throw issue(checked, node, "Missing translation block") }
            for statement in block.block.items {
                guard let group = GroupSyntax(statement), let tag = group.tag.literalValue else {
                    throw issue(checked, statement, "Translation language requires its checked literal tag")
                }
                let language = DeskLocalization.normalize(tag)
                // Unknown languages are the checker's warning, not a reason to reject otherwise valid content.
                // The runtime stores pure keys; it does not interpret a tag or assume it is a known ISO language.
                guard !language.isEmpty, written[language] == nil else {
                    throw issue(checked, statement, "Duplicate or empty normalized translation language")
                }
                count += 1
                var table: [String: String] = [:], values: [String: [ProgramTranslationPart]] = [:]
                for statement in group.block.items {
                    guard let entry = EntrySyntax(statement), let value = StringLiteralSyntax(entry.value.node) else {
                        throw issue(checked, statement, "Translation entries require literal keys and values")
                    }
                    let key = DeskTranslationKeys.key(of: entry.key, in: checked.tree)
                    guard table[key] == nil else { throw issue(checked, statement, "Duplicate translation key") }
                    table[key] = value.node.node.trimmedText
                    let original = placeholders(entry.key)
                    values[key] = try pattern(value, original: original, checked: checked, catalog: catalog)
                    _ = try pattern(entry.key, original: original, checked: checked, catalog: catalog)
                    count += 1 + (values[key]?.count ?? 0)
                    guard key.utf16.count <= min(ProgramLimits.maximumTextLength, catalog.limits.maximumTextLength),
                          count <= min(ProgramLimits.maximumExpressions, catalog.limits.maximumTokens) else {
                        throw DeskCompilationIssue(kind: .resourceLimit, file: checked.tree.file, range: statement.textRange,
                                                   message: "Shared program translation limit exceeded")
                    }
                }
                written[language] = table
                patterns[language] = values
            }
        }
        guard written == checked.translations.languages else {
            throw issue(checked, checked.tree.rootNode, "Translation table does not match its checked source")
        }
        return patterns
    }

    private static func placeholders(_ string: StringLiteralSyntax) -> [String] {
        string.segments.compactMap { segment in
            guard case .interpolation(let value) = segment else { return nil }
            return Checker.canonicalTokens(value.node.tokens.dropFirst().dropLast())
        }
    }

    private static func pattern(_ string: StringLiteralSyntax, original: [String], checked: CheckedFile,
                                catalog: DeskCatalog) throws -> [ProgramTranslationPart] {
        var parts: [ProgramTranslationPart] = [], used = Set<Int>(), length = 0
        if let literal = string.literalValue { parts = [.text(literal)]; length = literal.utf16.count }
        else {
            for segment in string.segments {
                switch segment {
                case .text(_, let cooked): parts.append(.text(cooked)); length += cooked.utf16.count
                case .foreign(let node): throw issue(checked, node, "Foreign translation interpolation is unsupported")
                case .interpolation(let value):
                    let key = Checker.canonicalTokens(value.node.tokens.dropFirst().dropLast())
                    guard let index = original.indices.first(where: { original[$0] == key && !used.contains($0) }) else {
                        throw issue(checked, value.node, "Translation placeholders differ from their source")
                    }
                    used.insert(index)
                    parts.append(.placeholder(index))
                }
            }
        }
        guard used.count == original.count else { throw issue(checked, string.node, "Translation is missing a source placeholder") }
        guard length <= min(ProgramLimits.maximumTextLength, catalog.limits.maximumTextLength),
              parts.count <= min(ProgramLimits.maximumExpressions, catalog.limits.maximumTokens) else {
            throw DeskCompilationIssue(kind: .resourceLimit, file: checked.tree.file, range: string.node.textRange,
                                       message: "Shared program translation pattern limit exceeded")
        }
        return parts
    }

    private static func issue(_ checked: CheckedFile, _ node: PositionedNode, _ message: String) -> DeskCompilationIssue {
        DeskCompilationIssue(kind: .invalidCheckedModel, file: checked.tree.file, range: node.textRange, message: message)
    }
}
