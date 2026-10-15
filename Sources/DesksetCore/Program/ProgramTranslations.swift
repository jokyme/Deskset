/// A checked translation changes words and the order of placeholders, never their expressions or formats.
public enum ProgramTranslationPart: Equatable, Sendable {
    case text(String)
    case placeholder(Int)
}

/// Pure patterns keyed by the source's canonical token spelling. The producer cooks text and matches each
/// placeholder to its source occurrence; Core neither parses translated code nor reads the system language.
public struct ProgramTranslations: Equatable, Sendable {
    public let source: [String: [ProgramTranslationPart]]
    public let languages: [String: [String: [ProgramTranslationPart]]]

    public init(source: [String: [ProgramTranslationPart]] = [:],
                languages: [String: [String: [ProgramTranslationPart]]] = [:]) {
        self.source = source
        self.languages = languages
    }

    /// Table entries and parts share the executable expression budget, counted once even when a key is reused.
    /// Validate every language, including unselected ones, before any scene can be projected.
    func validated() throws -> (placeholders: [String: Int], cost: Int) {
        var cost = 0
        func charge(_ amount: Int) throws {
            guard amount <= ProgramLimits.maximumExpressions - cost else { throw ProgramRuntimeError.expressionLimit }
            cost += amount
        }
        func pattern(_ parts: [ProgramTranslationPart]) throws -> Int {
            try charge(parts.count)
            var indices = Set<Int>(), length = 0
            for part in parts {
                switch part {
                case .text(let text):
                    let count = text.utf16.count
                    guard count <= ProgramLimits.maximumTextLength - length else { throw ProgramRuntimeError.invalidExpression }
                    length += count
                case .placeholder(let index):
                    guard index >= 0, index < ProgramLimits.maximumExpressions,
                          indices.insert(index).inserted else { throw ProgramRuntimeError.invalidExpression }
                }
            }
            guard indices.allSatisfy({ $0 < indices.count }) else { throw ProgramRuntimeError.invalidExpression }
            return indices.count
        }

        try charge(source.count)
        var placeholders: [String: Int] = [:]
        for (key, parts) in source {
            guard key.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
            placeholders[key] = try pattern(parts)
        }
        try charge(languages.count)
        for (language, entries) in languages {
            guard !language.isEmpty, language.utf16.count <= ProgramLimits.maximumTextLength else {
                throw ProgramRuntimeError.invalidExpression
            }
            try charge(entries.count)
            for (key, parts) in entries {
                guard let expected = placeholders[key], try pattern(parts) == expected else {
                    throw ProgramRuntimeError.invalidExpression
                }
            }
        }
        return (placeholders, cost)
    }

    func pattern(for key: String, language: String?) -> [ProgramTranslationPart]? {
        language.flatMap { languages[$0]?[key] } ?? source[key]
    }
}
