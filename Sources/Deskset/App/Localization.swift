import Foundation

/// The app's own text in the user's language: `L("Refresh All")`, or a printf format with its arguments
/// (`L("Deskset %@ is available", version)`); a format whose catalog entry has plural variations picks the form for
/// its number (`L("%lld skins", count)`).
///
/// The English text is the key of `Localization/Localizable.xcstrings`, which `scripts/build-app.sh` compiles into
/// `Contents/Resources/<language>.lproj`; macOS picks the language (System Settings → General → Language & Region →
/// Applications can set one for Deskset alone). Without .lproj folders (`swift run`, the self-tests) the English text
/// shows. `swift scripts/localization.swift check` (a CI step) keeps the keys in the code, the catalog and its
/// languages in step.
///
/// Not translated: log lines, command-line output, INI keys, bang names, and everything a skin draws — a skin's text
/// follows Rainmeter's rules (the Time measure's English default, FormatLocale…), not the app's language.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.text(key, arguments)
}

enum Localization {
    /// Where the .lproj folders are looked up (the self-tests use a temporary bundle).
    static var bundle = Bundle.main
    /// `--pseudo-language`: every translated text is lengthened and marked, to find text that is not translated and
    /// layouts that cut longer languages short.
    static var pseudo: PseudoLanguage?

    static func text(_ key: String, _ arguments: [CVarArg]) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        // Without arguments the text is not a format: a literal % stays as written. With them, the plural form is
        // chosen by the rules of the text's language (Russian "2 скина", "5 скинов"), not of the Mac's region.
        let text = arguments.isEmpty ? format
            : String(format: format, locale: Locale(identifier: bundle.preferredLocalizations.first ?? "en"),
                     arguments: arguments)
        return pseudo?.transform(text) ?? text
    }

    /// The languages of the catalog besides English: those of Rainmeter's translations, in macOS's codes.
    static let languages = ["ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "he", "hr", "hu", "id", "it",
                            "ja", "ko", "lt", "lv", "ms", "nb", "nl", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sl",
                            "sr", "sr-Latn", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]
}

/// The app's language as chosen in Settings › General: nil follows the Mac. It is the `AppleLanguages` key of
/// Deskset's own defaults domain — the key System Settings › General › Language & Region › Applications writes too —
/// so either place shows the other's choice; macOS reads it when Deskset starts.
struct LanguagePreference {
    let defaults: UserDefaults
    /// Deskset's defaults domain (the self-tests use a temporary suite).
    let domain: String

    static var standard: LanguagePreference {
        LanguagePreference(defaults: .standard, domain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    /// The chosen language, read from Deskset's own domain only: `defaults.object(forKey:)` would also find the
    /// Mac's languages in the global domain.
    var chosen: String? {
        (defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String])?.first
    }

    func choose(_ language: String?) {
        if let language { defaults.set([language], forKey: "AppleLanguages") }
        else { defaults.removeObject(forKey: "AppleLanguages") }
    }

    /// The language Deskset shows when it follows the Mac: the first of the Mac's languages it has.
    static func systemLanguage(preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: ["en"] + Localization.languages, forPreferences: preferences).first ?? "en"
    }

    /// The Mac's own languages (the global domain, which a choice for Deskset alone does not change).
    static var macLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? ["en"]
    }

    /// Every language Deskset has, each named in itself ("Deutsch", "日本語"), in alphabetical order.
    static var choices: [(language: String, name: String)] {
        (["en"] + Localization.languages).map { ($0, name(of: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A language's name in that language, capitalised as a menu item ("français" → "Français").
    static func name(of language: String) -> String {
        let locale = Locale(identifier: language)
        let name = locale.localizedString(forIdentifier: language) ?? language
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}

/// A made-up language for checking the app's UI (`--pseudo-language long|rtl`): `long` turns "Refresh All" into
/// "⟦Ŕéƒŕéšĥ Åļļ~~~~⟧" — about 40% longer, as German or Finnish text often is, with marks that show where a text was
/// cut or never went through `L`; `rtl` also lays the app out right to left, as Arabic and Hebrew do.
enum PseudoLanguage: String {
    case long, rtl

    static let open = "⟦", close = "⟧"

    func transform(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let accented = String(text.map { PseudoLanguage.accents[$0] ?? $0 })
        return PseudoLanguage.open + accented + String(repeating: "~", count: max(1, text.count * 2 / 5))
            + PseudoLanguage.close
    }

    /// Whether a text went through `transform`.
    static func isPseudo(_ text: String) -> Bool { text.contains(open) }

    private static let accents: [Character: Character] = {
        let plain = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let marked = Array("åƀçđéƒĝĥîĵķļɱñöþǫŕšţûṽŵẋýžÅƁÇĐÉƑĜĤÎĴĶĻṀÑÖÞǪŔŠŢÛṼŴẊÝŽ")
        return Dictionary(uniqueKeysWithValues: zip(plain, marked))
    }()

    /// `--pseudo-language` before the app object exists: `rtl` must be set before AppKit reads the layout direction.
    static func configure(for arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--pseudo-language"), i + 1 < arguments.count,
              let language = PseudoLanguage(rawValue: arguments[i + 1]) else { return }
        Localization.pseudo = language
        if language == .rtl {
            // The argument domain, as `-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES` would: never
            // written to the user's preferences.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleTextDirection"] = true
            arguments["NSForceRightToLeftWritingDirection"] = true
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
    }
}
