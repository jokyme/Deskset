import AppKit
import DeskLanguage

enum DeskSymbolCatalogSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("Desk: platform symbols: native availability supplies warning facts without inventing OS versions") {
            let catalog = DeskSymbolCatalog()
            t.check(NSImage(systemSymbolName: "wifi", accessibilityDescription: nil) != nil)
            t.check(catalog.exists("wifi"))
            for name in ["", "\0", "wifi\0", "deskset.nonexistent.symbol.87fc2"] {
                t.check(!catalog.exists(name), name)
                t.equal(catalog.minimumMacOS(of: name), nil)
                t.equal(catalog.similarSymbols(to: name), [])
            }
            t.equal(catalog.minimumMacOS(of: "wifi"), nil, "current availability does not prove an introduction version")
        }

        t.suite("Desk: platform symbols: checked literals and conditional branches use the native provider") {
            let missing = "deskset.nonexistent.symbol.87fc2"
            for source in ["widget { Icon(\"\(missing)\") }",
                           "widget { Icon(system.dark ? \"wifi\" : \"\(missing)\") }"] {
                let tree = Desk.parse(source, fileName: "Symbols.desk")
                let without = Desk.check(tree)
                t.check(!without.diagnostics.contains { $0.id == .unknownSymbol }, "no provider means no guessed platform warning")
                let checked = Desk.check(tree, context: CheckContext(symbols: DeskSymbolCatalog()))
                let warnings = checked.diagnostics.filter { $0.id == .unknownSymbol }
                t.equal(warnings.count, 1)
                t.equal(warnings.first?.severity, .warning)
                t.check(checked.diagnostics(.error).isEmpty, "a missing symbol does not reject the widget")
                t.equal(warnings.first?.fixIts, [], "no invented replacement is offered")
            }
            let valid = Desk.check(Desk.parse("widget { Icon(\"wifi\") }", fileName: "Symbols.desk"),
                                   context: CheckContext(symbols: DeskSymbolCatalog()))
            t.check(!valid.diagnostics.contains { $0.id == .unknownSymbol })
        }
    }
}
