import Foundation

// The diagnostics as data: for each stable id, its severity, a short trigger, the message template in both
// languages, what each placeholder stands for, the texts that fill `{hint}`-style placeholders, and the fix-its.
// A diagnostic value made while checking holds no text; its message is rendered from these templates.

/// What a placeholder of a message template stands for, which decides how its value is rendered.
public enum PlaceholderKind: String, Sendable, Hashable {
    /// Desk text shown in backquotes as written, never translated: `cpuu`, `.font`.
    case code
    /// A display name from the catalog ("a number" / "数字").
    case displayName
    /// A display name without the examples it carries ("a text style", not "a text style, such as `.caption`"), for
    /// templates that list the choices themselves or put the name in the middle of a clause (§6.1).
    case shortName
    /// A sentence or phrase in both languages.
    case text
    /// Text shown as it is in every language, without backquotes: a version, a language tag, a font or file name.
    case plain
    /// A number: a line, a count, a limit, an amount.
    case number
    /// A list, joined with ", " / "、" and "or" / "或" (or "and" / "和") before the last item.
    case list
}

/// A diagnostic whose severity is higher in a stated case.
public struct Escalation: Sendable, Hashable {
    public var severity: Severity
    public var when: LocalizedText
    public init(severity: Severity, when: LocalizedText) {
        self.severity = severity
        self.when = when
    }
}

/// A text that fills a prose placeholder of a template (`{hint}`, `{reason}`, `{direction}`…), chosen by the case.
public struct HintSpec: Sendable, Hashable {
    /// Stable key, used by the code that reports the diagnostic (`"labels"`, `"noLabels"`, `"forHidden"`).
    public var key: String
    /// The placeholder it fills.
    public var placeholder: String
    public var text: LocalizedText
    public init(key: String, placeholder: String = "hint", text: LocalizedText) {
        self.key = key
        self.placeholder = placeholder
        self.text = text
    }
}

/// A fix-it a diagnostic offers.
public struct FixItSpec: Sendable, Hashable {
    /// The key of its button title in `DeskCatalog.fixItTitles`.
    public var titleKey: String
    /// Title arguments known in advance, as Desk text (`"text": "}"` for "Insert `}`").
    public var arguments: [String: String]
    /// When it is offered, if not every time the diagnostic is reported.
    public var offeredWhen: LocalizedText?
    /// Also part of the file's "Fix all".
    public var fixAll: Bool

    public init(_ titleKey: String, arguments: [String: String] = [:], offeredWhen: LocalizedText? = nil,
                fixAll: Bool = false) {
        self.titleKey = titleKey
        self.arguments = arguments
        self.offeredWhen = offeredWhen
        self.fixAll = fixAll
    }
}

/// The title of a fix-it button, with placeholders for its arguments ("Insert `{text}`" / "插入 `{text}`").
public struct FixItTitleSpec: Sendable, Hashable {
    public var key: String
    public var title: LocalizedText
    public init(key: String, title: LocalizedText) {
        self.key = key
        self.title = title
    }
}

/// The message of a secondary location ("declared here", "the other copy").
public struct NoteSpec: Sendable, Hashable {
    public var key: String
    public var text: LocalizedText
    public init(key: String, text: LocalizedText) {
        self.key = key
        self.text = text
    }
}

public struct DiagnosticSpec: Sendable, Hashable {
    public var id: DiagnosticID
    public var severity: Severity
    public var escalation: Escalation?
    /// A short piece of code (or a description) that produces it.
    public var trigger: String
    /// The message, with `{placeholder}`s.
    public var template: LocalizedText
    /// What each placeholder of the template stands for.
    public var placeholders: [String: PlaceholderKind]
    public var hints: [HintSpec]
    public var fixIts: [FixItSpec]

    public init(id: DiagnosticID, severity: Severity, escalation: Escalation? = nil, trigger: String,
                template: LocalizedText, placeholders: [String: PlaceholderKind], hints: [HintSpec] = [],
                fixIts: [FixItSpec] = []) {
        self.id = id
        self.severity = severity
        self.escalation = escalation
        self.trigger = trigger
        self.template = template
        self.placeholders = placeholders
        self.hints = hints
        self.fixIts = fixIts
    }

    /// The placeholder names a template uses, in order of first use: `{name}` where the name starts with a letter
    /// and continues with letters and digits. `{{`, `}}`, `{ … }` and other braces are text.
    public static func placeholderNames(in template: String) -> [String] {
        var names: [String] = []
        let scalars = Array(template.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "{" else { i += 1; continue }
            if i + 1 < scalars.count, scalars[i + 1] == "{" { i += 2; continue }
            var j = i + 1
            var name = ""
            while j < scalars.count, scalars[j].properties.isAlphabetic || ("0"..."9").contains(scalars[j]),
                  scalars[j].isASCII {
                name.unicodeScalars.append(scalars[j])
                j += 1
            }
            if j < scalars.count, scalars[j] == "}", let first = name.unicodeScalars.first,
               first.properties.isAlphabetic {
                if !names.contains(name) { names.append(name) }
                i = j + 1
            } else {
                i += 1
            }
        }
        return names
    }

    /// The template of `language` with the placeholders that `values` names replaced by their text as given;
    /// the others are left as written. The full rendering (display names, lists, code in backquotes) belongs to the
    /// diagnostics module; this is the plain substitution it builds on.
    public func render(_ language: DiagnosticLanguage, _ values: [String: String]) -> String {
        Self.substitute(template.text(in: language), values)
    }

    static func substitute(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        let scalars = Array(template.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "{" {
                var j = i + 1
                var name = ""
                while j < scalars.count, scalars[j].isASCII,
                      scalars[j].properties.isAlphabetic || ("0"..."9").contains(scalars[j]) {
                    name.unicodeScalars.append(scalars[j])
                    j += 1
                }
                if j < scalars.count, scalars[j] == "}", !name.isEmpty, let value = values[name],
                   !(i > 0 && scalars[i - 1] == "{") {
                    out += value
                    i = j + 1
                    continue
                }
            }
            out.unicodeScalars.append(scalars[i])
            i += 1
        }
        return out
    }
}

extension DiagnosticID {
    /// `"DK3001"`.
    public var code: String { rawValue }
    /// The area: 1 lexical, 2 structure, 3 names, 4 types and values, 5 modifiers and styles, 6 layout, 7 actions,
    /// 8 info, options, security, versions and limits, 9 foreign syntax.
    public var area: Int { Int(String(rawValue.dropFirst(2).prefix(1))) ?? 0 }
    /// The number without the `DK` prefix.
    public var number: Int { Int(rawValue.dropFirst(2)) ?? 0 }
    /// The symbolic name used in code and fixtures (`unknownModifier`).
    public var symbolicName: String { String(describing: self) }
}
