import Foundation

/// Language tags of a widget's `translations` (§8.6, D128): normalizing the tags people write, and choosing the
/// display language from the Mac's preferred languages.
public enum DeskLocalization {
    /// `_` becomes `-`; the Chinese region tags people write name their script (`zh-CN`, `zh-SG` → `zh-Hans`;
    /// `zh-TW` → `zh-Hant`; `zh-HK`, `zh-MO` → `zh-Hant-HK`, `zh-Hant-MO`); a language gets its likely script when
    /// that script is not the usual Latin one (`zh` → `zh-Hans`, `sr-RS` → `sr-Cyrl-RS`).
    public static func normalize(_ tag: String) -> String {
        var parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased() else { return tag }
        parts[0] = language
        let hasScript = parts.count > 1 && parts[1].count == 4
        let region = parts.dropFirst().first { $0.count == 2 || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }?.uppercased()
        if language == "zh" && !hasScript {
            switch region {
            case "TW"?: return "zh-Hant"
            case "HK"?, "MO"?: return "zh-Hant-\(region!)"
            case "CN"?, "SG"?, nil: return "zh-Hans"
            default: return "zh-Hans-\(region!)"
            }
        }
        if !hasScript, let script = likelyScripts[language] {
            return ([language, script] + (region.map { [$0] } ?? [])).joined(separator: "-")
        }
        return parts.joined(separator: "-")
    }

    /// Languages whose usual script is not Latin, so a tag without a script names it.
    static let likelyScripts: [String: String] = ["sr": "Cyrl", "uz": "Latn"]

    /// Languages written in one usual script, so the language alone matches (`de`, `ja`).
    static func hasOneUsualScript(_ language: String) -> Bool { language != "zh" && language != "sr" }

    /// The widget's tag (as written) to show for the Mac's preferred languages, or nil for the source (English).
    /// For each preferred language in order: the exact normalized tag, then the same language and script with any
    /// region, then the language alone when it has one usual script.
    public static func displayLanguage(available: [String], preferred: [String]) -> String? {
        let normalized = available.map { ($0, normalize($0)) }
        for wanted in preferred.map(normalize) {
            if let exact = normalized.first(where: { $0.1 == wanted }) { return exact.0 }
            let parts = wanted.split(separator: "-").map(String.init)
            let languageAndScript = parts.count > 1 && parts[1].count == 4 ? "\(parts[0])-\(parts[1])" : parts[0]
            if let sameScript = normalized.first(where: { tag in
                let p = tag.1.split(separator: "-").map(String.init)
                let ls = p.count > 1 && p[1].count == 4 ? "\(p[0])-\(p[1])" : p[0]
                return ls == languageAndScript
            }) {
                return sameScript.0
            }
            if hasOneUsualScript(parts[0]),
               let language = normalized.first(where: { $0.1.split(separator: "-").first.map(String.init) == parts[0] }) {
                return language.0
            }
        }
        return nil
    }
}
