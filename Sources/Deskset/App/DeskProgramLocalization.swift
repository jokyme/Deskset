import Foundation
import DeskLanguage
import DesksetCore

/// A widget chooses a translation table when it loads. Formatting uses that display language while retaining
/// the Mac's region, calendar and other locale components; the Studio's interface language is independent.
struct DeskProgramLocalization: Equatable {
    let language: String?
    let locale: Locale
    let name: String

    init(program: WidgetProgram, preferredLanguages: [String], locale: Locale) {
        language = DeskLocalization.displayLanguage(available: program.translations.languages.keys.sorted(),
                                                    preferred: preferredLanguages)
        var components = Locale.components(fromIdentifier: locale.identifier)
        let selected = Locale.components(fromIdentifier: language ?? "en")
        components[NSLocale.Key.languageCode.rawValue] = selected[NSLocale.Key.languageCode.rawValue] ?? "en"
        components[NSLocale.Key.scriptCode.rawValue] = selected[NSLocale.Key.scriptCode.rawValue]
        self.locale = Locale(identifier: Locale.identifier(fromComponents: components))
        name = program.displayName(language: language)
    }
}
