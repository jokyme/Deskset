import Foundation

// Rendering diagnostics (§6.1, D120). A diagnostic holds no text in any language: its message is the catalog's
// template in the requested language with each argument rendered by what its placeholder stands for — Desk code as
// written, display names from the catalog, prose in that language, lists joined the way the language joins them. A
// sentence whose placeholder has no value (a "Did you mean" without a suggestion) is left out.

extension Diagnostic {
    /// The message in `language`.
    public func message(in language: DiagnosticLanguage, catalog: DeskCatalog = .current) -> String {
        guard let spec = catalog.diagnostic(id) else { return id.rawValue }
        return DiagnosticRenderer.render(spec.template.text(in: language), arguments: arguments, kinds: spec.placeholders,
                                         language: language, catalog: catalog, capitalize: true)
    }

    /// The titles of the fix-its in `language`.
    public func fixItTitles(in language: DiagnosticLanguage, catalog: DeskCatalog = .current) -> [String] {
        fixIts.map { $0.title(in: language, catalog: catalog) }
    }
}

extension Note {
    public func message(in language: DiagnosticLanguage, catalog: DeskCatalog = .current) -> String {
        guard let spec = catalog.index.notes[messageKey] else { return messageKey }
        return DiagnosticRenderer.render(spec.text.text(in: language), arguments: arguments, kinds: [:], language: language,
                                         catalog: catalog, capitalize: false)
    }
}

extension FixIt {
    /// The button title in `language`: "Fix" / "改正", "Insert `}`" / "插入 `}`".
    public func title(in language: DiagnosticLanguage, catalog: DeskCatalog = .current) -> String {
        guard let spec = catalog.index.fixItTitles[titleKey] else { return titleKey }
        var kinds: [String: PlaceholderKind] = [:]
        for name in DiagnosticSpec.placeholderNames(in: spec.title.en) { kinds[name] = .code }
        kinds["line"] = .number
        return DiagnosticRenderer.render(spec.title.text(in: language), arguments: titleArguments, kinds: kinds,
                                         language: language, catalog: catalog, capitalize: false)
    }
}

enum DiagnosticRenderer {
    static func render(_ template: String, arguments: [String: DiagnosticArgument], kinds: [String: PlaceholderKind],
                       language: DiagnosticLanguage, catalog: DeskCatalog, capitalize: Bool) -> String {
        var text = template
        // Leave out the sentences whose placeholders have no value.
        for name in DiagnosticSpec.placeholderNames(in: text) where arguments[name] == nil {
            text = removeSentence(containing: "{\(name)}", from: text, language: language)
        }
        var values: [String: String] = [:]
        for name in DiagnosticSpec.placeholderNames(in: text) {
            guard let argument = arguments[name] else { values[name] = ""; continue }
            values[name] = renderArgument(argument, kind: kinds[name] ?? .code, arguments: arguments, kinds: kinds,
                                          language: language, catalog: catalog)
        }
        var result = DiagnosticSpec.substitute(text, values)
        if capitalize && language == .english {
            // A value that starts a sentence gets a capital letter.
            for name in DiagnosticSpec.placeholderNames(in: text)
                where kinds[name] == .displayName || kinds[name] == .text || kinds[name] == .list {
                guard startsSentence(name, in: text) else { continue }
                if let value = values[name], let first = value.first, first.isLowercase {
                    let capitalized = first.uppercased() + value.dropFirst()
                    if let r = result.range(of: value) { result.replaceSubrange(r, with: capitalized) }
                }
            }
        }
        return tidy(result, language: language)
    }

    static func renderArgument(_ argument: DiagnosticArgument, kind: PlaceholderKind, arguments: [String: DiagnosticArgument],
                               kinds: [String: PlaceholderKind], language: DiagnosticLanguage, catalog: DeskCatalog,
                               inList: Bool = false) -> String {
        switch argument {
        case .code(let s):
            // The template writes the backquotes around code placeholders; elsewhere code is shown in backquotes.
            if !inList && (kind == .code || kind == .plain || kind == .number) { return s }
            return "`\(s)`"
        case .text(let t):
            // Prose may hold placeholders of its own (`{number}` in a hint).
            return render(t.text(in: language), arguments: arguments, kinds: kinds, language: language, catalog: catalog,
                          capitalize: false)
        case .name(let id):
            return catalog.displayText(id, in: language)
        case .type(let t):
            return catalog.displayText(for: t, in: language)
        case .number(let n):
            return String(n)
        case .list(let items, let joiner):
            let rendered = items.map {
                renderArgument($0, kind: .list, arguments: arguments, kinds: kinds, language: language, catalog: catalog,
                               inList: true)
            }
            return DeskCatalog.joinedList(rendered, in: language, or: joiner == .or)
        }
    }

    /// Whether `{name}` starts a sentence of `template` (not inside backquotes).
    static func startsSentence(_ name: String, in template: String) -> Bool {
        guard let r = template.range(of: "{\(name)}") else { return false }
        let before = template[..<r.lowerBound]
        if before.last == "`" || before.last == "." { return false }
        let trimmed = before.reversed().drop { $0 == " " }
        guard let last = trimmed.first else { return true }
        return [".", "!", "?", "—"].contains(last)
    }

    /// Removes the sentence (or, in Chinese, the clause) that holds `placeholder`.
    static func removeSentence(containing placeholder: String, from text: String, language: DiagnosticLanguage) -> String {
        guard let r = text.range(of: placeholder) else { return text }
        let before = text[..<r.lowerBound]
        let after = text[r.upperBound...]
        let startMarkers: [String] = language == .english ? [". ", "? ", "! ", ": "] : ["。", "？", "！", "，", "："]
        var start = text.startIndex
        for marker in startMarkers {
            if let m = before.range(of: marker, options: .backwards), m.upperBound > start {
                start = language == .english ? m.upperBound : m.lowerBound
            }
        }
        let endMarkers: [Character] = language == .english ? [".", "?", "!"] : ["。", "？", "！"]
        var end = text.endIndex
        var index = after.startIndex
        while index < after.endIndex {
            if endMarkers.contains(after[index]) {
                let next = after.index(after: index)
                // A period inside code (`x.y`) is not the end of a sentence.
                if language == .english, next < after.endIndex, after[next] != " " { index = next; continue }
                end = next
                break
            }
            index = after.index(after: index)
        }
        var result = String(text[..<start]) + String(text[end...])
        result = result.trimmingCharacters(in: .whitespaces)
        if language == .simplifiedChinese, !result.isEmpty, let last = result.last, !"。？！".contains(last) { result += "。" }
        if language == .english, !result.isEmpty, let last = result.last, !".?!".contains(last) { result += "." }
        return result
    }

    /// Collapses the spaces and punctuation an empty value leaves behind.
    static func tidy(_ text: String, language: DiagnosticLanguage) -> String {
        var t = text
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.replacingOccurrences(of: #"\s+([.,])(\s|$)"#, with: "$1$2", options: .regularExpression)
        t = t.replacingOccurrences(of: "``", with: "")
        return t.trimmingCharacters(in: .whitespaces)
    }
}
