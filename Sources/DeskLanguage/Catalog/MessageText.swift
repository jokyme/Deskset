import Foundation

// The catalog's part of rendering a message (§6.1, D120): display names in a language, lists joined the way each
// language joins them, and a capital letter for a display name that starts a sentence. A diagnostic holds no text;
// its message is its template with each argument rendered by these.

extension DeskCatalog {
    /// A display name in `language`: `"type:bool"` → "yes or no (`true` or `false`)" / "是或否（`true` 或 `false`）".
    /// An id with no row reads "a value" / "一个值", so a message never shows an id.
    public func displayText(_ id: String, in language: DiagnosticLanguage, plural: Bool = false) -> String {
        guard let spec = displayName(id) else { return LocalizedText("a value", "一个值").text(in: language) }
        return (plural ? spec.plural ?? spec.name : spec.name).text(in: language)
    }

    /// A type's display name in `language`: "a list of days of a month", "a length in points, such as `12` or a text
    /// style, such as `.caption`".
    public func displayText(for type: DeskType, in language: DiagnosticLanguage) -> String {
        displayName(for: type).text(in: language)
    }

    /// Items joined as each language joins them: "a, b or c" / "a、b 或 c" (`or`), "a, b and c" / "a、b 和 c".
    /// Lists longer than eight are cut after the eighth with "…".
    public static func joinedList(_ items: [String], in language: DiagnosticLanguage, or: Bool) -> String {
        let english = language == .english
        let separator = english ? ", " : "、"
        guard items.count <= 8 else { return items.prefix(8).joined(separator: separator) + separator + "…" }
        let last = english ? (or ? " or " : " and ") : (or ? " 或 " : " 和 ")
        return joined(items, separator: separator, last: last)
    }
}

extension DiagnosticSpec {
    /// The message of `language` with the placeholders that `values` names replaced by their text as given (the
    /// others are left as written). In English, a value that starts a sentence — at the start of the template or
    /// after ". " — gets a capital letter ("The progress bar …", from the display name "the progress bar").
    public func message(_ language: DiagnosticLanguage, _ values: [String: String]) -> String {
        var capitalized = values
        if language == .english {
            let template = self.template.en
            for name in DiagnosticSpec.placeholderNames(in: template) where DiagnosticSpec.startsSentence(name, in: template) {
                if let value = values[name], let first = value.first, first.isLowercase {
                    capitalized[name] = first.uppercased() + value.dropFirst()
                }
            }
        }
        return render(language, capitalized)
    }

    /// Whether `{name}` stands at the start of a sentence of `template`.
    static func startsSentence(_ name: String, in template: String) -> Bool {
        var search = template[...]
        while let r = search.range(of: "{\(name)}") {
            let before = template[..<r.lowerBound]
            let trimmed = before.reversed().drop { $0 == " " }
            if trimmed.first == nil || [".", "!", "?", "—"].contains(trimmed.first!) { return true }
            search = template[r.upperBound...]
        }
        return false
    }
}
