import Foundation

/// The documentation every catalog item carries: one or two plain sentences in both languages, an example of at
/// most three lines that checks clean, the release that introduced it, what it corresponds to in Rainmeter, the
/// words people guess for it, and its popularity.
public struct Doc: Sendable, Hashable {
    public var en: String
    public var zh: String
    /// At most three lines of Desk. It must check clean where `exampleContext` puts it.
    public var example: String
    public var exampleContext: ExampleContext
    /// The Deskset release that introduced it; also breaks ties between candidates (earliest wins).
    public var since: AppVersion
    /// Mac-specific: no Rainmeter counterpart, or a Deskset extension to one.
    public var macOnly: Bool
    /// Needs this macOS version or later; older systems fall back as the entry says.
    public var minimumMacOS: Int?
    /// What it corresponds to in Rainmeter.
    public var rainmeter: [RainmeterMapping]
    /// Synonyms in both languages, the Rainmeter spelling first; used to suggest the right name for a wrong guess.
    public var keywords: [String]
    public var deprecated: Deprecation?
    /// Popularity, 0–100: completion order, choice lists, and the last tie-break of suggestions.
    public var rank: Int

    public init(en: String, zh: String, example: String, exampleContext: ExampleContext = ExampleContext(),
                since: AppVersion = .deskFirstRelease, macOnly: Bool = false, minimumMacOS: Int? = nil,
                rainmeter: [RainmeterMapping] = [], keywords: [String] = [], deprecated: Deprecation? = nil,
                rank: Int = 50) {
        self.en = en
        self.zh = zh
        self.example = example
        self.exampleContext = exampleContext
        self.since = since
        self.macOnly = macOnly
        self.minimumMacOS = minimumMacOS
        self.rainmeter = rainmeter
        self.keywords = keywords
        self.deprecated = deprecated
        self.rank = rank
    }

    public var text: LocalizedText { LocalizedText(en: en, zh: zh) }
}

extension AppVersion {
    /// The first Deskset release that ships Desk. Every item of the first catalog has this `since`.
    public static let deskFirstRelease = AppVersion(major: 1, minor: 0, patch: 0)
}

/// What a catalog item corresponds to in Rainmeter: a meter or measure type, one of its options (and a value of
/// it), a setting of the skin or its window, a variable, a bang or the context menu.
public struct RainmeterMapping: Sendable, Hashable {
    public enum Owner: Sendable, Hashable {
        /// A meter type (`String`, `Bar`…); an empty type stands for the options every meter reads.
        case meter(type: String)
        /// A measure type, or `Plugin` with the plugin's name; an empty type stands for the options every measure
        /// reads.
        case measure(type: String, plugin: String?)
        /// The `[Rainmeter]` section.
        case skin
        /// The per-skin window settings.
        case window
        /// The `[Metadata]` section.
        case metadata
        /// A variable: `#Name#` or a built-in one.
        case variables
        /// A bang (the key is its name, `!SetOption`), or a bracketed path or address when the key is nil.
        case bang
        case contextMenu
    }

    public enum Fidelity: String, Sendable, Hashable {
        /// The same behavior.
        case exact
        /// Similar; the behavior differs in the ways the note says.
        case approximate
        /// Only part of it.
        case partial
    }

    public var owner: Owner
    /// The option (`FontColor`, `PowerState`); nil: the meter or measure itself.
    public var key: String?
    /// The option's value (`Percent` in `PowerState=Percent`).
    public var value: String?
    public var fidelity: Fidelity
    public var note: String

    public init(_ owner: Owner, key: String? = nil, value: String? = nil, fidelity: Fidelity = .exact,
                note: String = "") {
        self.owner = owner
        self.key = key
        self.value = value
        self.fidelity = fidelity
        self.note = note
    }

    /// How the mapping is written in Rainmeter, for search and hover help: `Meter=Bar`, `FontColor`,
    /// `PowerState=Percent`, `[!SetOption …]`, `[!CommandMeasure … "Play"]`.
    public var spelling: String {
        if case .bang = owner, let key {
            return value.map { "[\(key) … \"\($0)\"]" } ?? "[\(key) …]"
        }
        if let key {
            if let value { return "\(key)=\(value)" }
            return key
        }
        switch owner {
        case .meter(let type): return type.isEmpty ? "Meter" : "Meter=\(type)"
        case .measure(let type, let plugin):
            if let plugin { return "Plugin=\(plugin)" }
            return type.isEmpty ? "Measure" : "Measure=\(type)"
        case .skin: return "[Rainmeter]"
        case .window: return "Rainmeter.ini"
        case .metadata: return "[Metadata]"
        case .variables: return "[Variables]"
        case .bang: return note.isEmpty ? "[\"…\"]" : note
        case .contextMenu: return "ContextTitle"
        }
    }

    /// The words of this mapping that people type when they look for it (key, value, meter or measure type); a
    /// bang without its `!`.
    public var searchTerms: [String] {
        var terms: [String] = []
        if let key { terms.append(key.hasPrefix("!") ? String(key.dropFirst()) : key) }
        if let value { terms.append(value) }
        switch owner {
        case .meter(let type) where !type.isEmpty: terms.append(type)
        case .measure(let type, let plugin):
            if let plugin { terms.append(plugin) } else if !type.isEmpty { terms.append(type) }
        default: break
        }
        return terms
    }
}
