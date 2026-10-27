import AppKit
import DesksetCore

/// `L`, its formats and plural forms (over a temporary bundle, not the app's), and the made-up language that shows
/// text which does not go through `L`.
enum LocalizationSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: localization: lookups, formats and plural forms") {
            let previous = Localization.bundle
            defer { Localization.bundle = previous }
            Localization.bundle = try bundle(t, language: "ru", strings: [
                "Refresh All": "Обновить все",
                "Deskset %@ is available": "Доступен Deskset %@",
                "Version %@ → %@": "Версия %2$@ ← %1$@",
            ], plurals: ["Contains %lld skins.": ["one": "%lld скин.", "few": "%lld скина.", "many": "%lld скинов.",
                                                   "other": "%lld скина."]])
            t.equal(L("Refresh All"), "Обновить все")
            t.equal(L("Deskset %@ is available", "1.2"), "Доступен Deskset 1.2")
            t.equal(L("Version %@ → %@", "1", "2"), "Версия 2 ← 1", "positional arguments may change order")
            t.equal(L("Not in the catalog"), "Not in the catalog", "a missing text shows the English key")
            t.equal(L("100% sure"), "100% sure", "without arguments a text is not a format")
            t.equal(L("%lld%% done", 50), "50% done")
            t.equal([1, 2, 5, 21, 111].map { L("Contains %lld skins.", $0) },
                    ["1 скин.", "2 скина.", "5 скинов.", "21 скин.", "111 скинов."])

            Localization.bundle = try bundle(t, language: "en", strings: [:],
                                             plurals: ["Contains %lld skins.": ["one": "Contains %lld skin.",
                                                                               "other": "Contains %lld skins."]])
            t.equal(L("Contains %lld skins.", 1), "Contains 1 skin.")
            t.equal(L("Contains %lld skins.", 3), "Contains 3 skins.")
        }

        t.suite("App: localization: the made-up language") {
            let long = PseudoLanguage.long.transform("Refresh All")
            t.check(PseudoLanguage.isPseudo(long))
            t.check(!PseudoLanguage.isPseudo("Refresh All"))
            t.check(long.count >= "Refresh All".count * 7 / 5, "about 40% longer: \(long)")
            t.equal(PseudoLanguage.long.transform(""), "")
            t.check(!long.contains("e"), "letters are swapped for accented ones: \(long)")
            t.equal(PseudoLanguage(rawValue: "rtl"), .rtl)
            t.equal(PseudoLanguage(rawValue: "klingon"), nil)
        }

        t.suite("App: localization: the app's menus and windows show only translated text") {
            guard let app = try AppSelfTest.makeApp(t),
                  let focus = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            let previous = Localization.pseudo
            Localization.pseudo = .long
            defer { Localization.pseudo = previous }

            // What the skins and the Mac put in the UI is data, not the app's text.
            var data: Set<String> = ["Deskset", "TextEdit", "%", "~100%", "@0", "–", "—", "·", "…"]
            for config in app.library {
                data.insert(config.name)
                data.formUnion(config.name.split(separator: "\\").map(String.init))
                for file in config.files {
                    data.insert(file)
                    data.insert((file as NSString).deletingPathExtension)
                    let metadata = ManageModel.readMetadata(config.directory.appendingPathComponent(file)).values
                    data.formUnion(metadata)
                    data.formUnion(metadata.map(ManageModel.informationText))
                }
            }
            // Rainmeter's About keys, kept in English for bug reports (scripts/localization-ignore.tsv).
            data.formUnion(["Path:", "IniFile:", "SkinPath:", "SettingsPath:", "LogFile:"])
            for screen in NSScreen.screens { data.insert(screen.localizedName) }
            func isData(_ text: String) -> Bool {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || data.contains(trimmed) { return true }
                if trimmed.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count < 2 { return true }
                if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed.contains("\\") { return true }
                // Skin metadata, custom skin actions, app and folder names, versions, file names.
                return trimmed.range(of: #"^(v?\d|@\d)"#, options: .regularExpression) != nil
                    || trimmed.range(of: #"\.(ini|app|rmskin|zip|txt)$"#, options: .regularExpression) != nil
            }
            var untranslated: [String] = []
            func visit(_ text: String?, _ place: String) {
                guard let text, !PseudoLanguage.isPseudo(text), !isData(text) else { return }
                untranslated.append("\(place): \(text)")
            }
            func visit(menu: NSMenu, _ place: String) {
                for item in menu.items where !item.isSeparatorItem {
                    visit(item.title, place)
                    visit(item.toolTip, place)
                    if let submenu = item.submenu { visit(menu: submenu, place + " › " + item.title) }
                }
            }
            func visit(view: NSView, _ place: String) {
                if view.isHidden { return }
                visit(view.toolTip, place)
                switch view {
                case let popUp as NSPopUpButton:
                    if let menu = popUp.menu { visit(menu: menu, place + " pop-up") }
                case let button as NSButton:
                    // An image-only button keeps AppKit's unseen default title.
                    if button.imagePosition != .imageOnly { visit(button.title, place) }
                case let field as NSTextField where !field.isEditable:
                    visit(field.stringValue, place)
                    visit(field.placeholderString, place)
                case let segments as NSSegmentedControl:
                    for i in 0..<segments.segmentCount { visit(segments.label(forSegment: i), place) }
                default: break
                }
                for subview in view.subviews { visit(view: subview, place) }
            }

            visit(menu: MainMenu.make(app: app), "main menu")
            let status = NSMenu()
            app.buildMainMenu(status)
            visit(menu: status, "menu bar menu")
            let skinMenu = app.skinMenu(for: focus, includeCustomItems: false)
            // The first item is the skin's own name.
            skinMenu.items.first.map { data.insert($0.title) }
            visit(menu: skinMenu, "skin menu")

            // Fake editors: the icon service is never asked (IconServiceGuard).
            CodeEditorRoutingSelfTests.withFakes(.init(), .init()) {
                let settings = SettingsWindowController(app: app)
                data.formUnion(settings.detectedEditors.map(\.name))
                for pane in SettingsWindowController.Pane.allCases {
                    settings.select(pane)
                    if let content = settings.window?.contentView { visit(view: content, "Settings \(pane)") }
                    visit(settings.window?.title, "Settings title")
                }
                settings.close()
            }
            let about = AboutWindowController(app: app)
            if let content = about.window?.contentView { visit(view: content, "About") }
            visit(about.window?.title, "About title")
            about.close()
            let manage = ManageWindowController(app: app)
            manage.select(config: "App\\Focus", file: "Focus.ini")
            for tab in [ManageWindowController.Tab.skins, .layouts] {
                manage.selectTab(tab)
                if let content = manage.window?.contentView { visit(view: content, "Manage \(tab)") }
            }
            visit(manage.window?.title, "Manage title")
            manage.close()
            t.equal(untranslated, [], "text that does not go through L")
        }
    }

    /// A bundle with one localization (also its development region, so that it is used whatever the Mac's languages).
    private static func bundle(_ t: AppTestRunner, language: String, strings: [String: String],
                               plurals: [String: [String: String]]) throws -> Bundle {
        let root = t.temporaryDirectory("localization-\(language)").appendingPathComponent("Test.bundle")
        let lproj = root.appendingPathComponent("Contents/Resources/\(language).lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleDevelopmentRegion": language, "CFBundleIdentifier": "test.localization.\(language)"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
            .write(to: lproj.appendingPathComponent("Localizable.strings"))
        var dictionary: [String: Any] = [:]
        for (key, forms) in plurals {
            var rule: [String: String] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                                          "NSStringFormatValueTypeKey": "lld"]
            rule.merge(forms) { $1 }
            dictionary[key] = ["NSStringLocalizedFormatKey": "%#@value@", "value": rule]
        }
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            .write(to: lproj.appendingPathComponent("Localizable.stringsdict"))
        guard let bundle = Bundle(url: root) else { throw CocoaError(.fileReadUnknown) }
        return bundle
    }
}
