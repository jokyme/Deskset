import AppKit
import CoreText
import CryptoKit
import DeskLanguage
import DesksetCore
import Foundation

enum DeskFontCatalogSelfTests {
    static func run(_ t: AppTestRunner) {
        catalogTests(t)
        serviceTests(t)
        fileTests(t)
    }

    private static func catalogTests(_ t: AppTestRunner) {
        t.suite("Desk: platform fonts: native families take precedence over Windows substitution and System aliases") {
            let catalog = DeskFontCatalog()
            guard let installed = Fonts.installedFamilyNames.sorted().first else {
                return t.check(false, "CoreText did not list an actual installed family")
            }
            t.check(catalog.isInstalled(family: installed.lowercased()), "native family lookup is case insensitive")
            t.equal(catalog.macSubstitute(forWindowsFamily: installed), nil, "installed families are never substitution warnings")
            guard let windows = installedMappedFamily() else {
                return t.check(false, "no real installed family also present in the Windows substitution table is available")
            }
            t.equal(catalog.macSubstitute(forWindowsFamily: windows), nil, "the real installed \(windows) wins")
            let missing = "Deskset Missing Family 7B4DC19E"
            t.equal(Fonts.installedFamily(named: missing), nil, "the missing-family control is absent in CoreText")
            t.check(!catalog.isInstalled(family: missing), "unknown families are not resolved through a fallback font")
            t.equal(catalog.macSubstitute(forWindowsFamily: missing), nil, "an unknown family is not called Windows")
            for (family, replacement) in [("Consolas", "Menlo"), ("Segoe UI", "System Font")] {
                t.equal(catalog.macSubstitute(forWindowsFamily: family),
                        Fonts.installedFamily(named: family) == nil ? replacement : nil, family)
            }
            for name in ["System", "System Mono", "SF Mono", "New York", "system-ui", "System Font"] {
                t.check(catalog.isInstalled(family: name), "the existing app face \(name) is usable")
                t.equal(catalog.macSubstitute(forWindowsFamily: name), nil, "\(name) is not a Windows family")
            }
            for invalid in ["", " \t ", "\0", "System\0"] {
                t.check(!catalog.isInstalled(family: invalid), "invalid family lookup is false")
                t.equal(catalog.macSubstitute(forWindowsFamily: invalid), nil)
                t.equal(catalog.similarFamilies(to: invalid), [])
            }
        }
    }

    private static func serviceTests(_ t: AppTestRunner) {
        t.suite("Desk: platform fonts: checker diagnostics and service completion consume the actual catalog") {
            let catalog = DeskFontCatalog()
            guard let helvetica = Fonts.installedFamily(named: "Helvetica"),
                  let neue = Fonts.installedFamily(named: "Helvetica Neue") else {
                return t.check(false, "the native Helvetica controls are unavailable")
            }
            func fontDiagnostics(_ family: String, fonts: FontCataloging? = DeskFontCatalog()) -> [Diagnostic] {
                let checked = Desk.check(Desk.parse(widget(family), fileName: "Fonts.desk"),
                                         context: CheckContext(fonts: fonts))
                t.check(checked.tree.diagnostics.isEmpty, "the font check fixture parsed")
                return checked.diagnostics.filter { $0.id == .fontNotInstalled || $0.id == .windowsFont }
            }
            t.equal(fontDiagnostics(helvetica).map(\.id), [], "an installed family is accepted by the checker")
            guard let installedWindows = installedMappedFamily() else {
                return t.check(false, "the installed substitution precedence fixture is unavailable")
            }
            t.equal(fontDiagnostics(installedWindows).map(\.id), [], "the checker accepts installed \(installedWindows) without DK4033")
            let missing = "Deskset Missing Family 7B4DC19E"
            t.equal(fontDiagnostics(missing, fonts: nil).map(\.id), [], "without platform fonts this check is not made")
            t.equal(fontDiagnostics(missing).map(\.id), [.fontNotInstalled], "the injected catalog enables DK4032")
            t.equal(fontDiagnostics("Consolas").map(\.id),
                    Fonts.installedFamily(named: "Consolas") == nil ? [.windowsFont] : [], "Windows substitution reaches DK4033")
            for name in ["System", "System Rounded", "System Mono", "System Serif", "SF Mono", "New York", "system-ui"] {
                t.equal(fontDiagnostics(name).map(\.id), [], "\(name) is accepted without a Windows warning")
            }
            let misspelling = fontDiagnostics("Helvetcia")
            t.equal(misspelling.map(\.id), [.fontNotInstalled])
            t.check(misspelling.first?.fixIts.first?.edits.contains { $0.replacement == "\"\(helvetica)\"" } == true,
                    "the existing edit-distance helper supplies the checker fix-it")
            t.equal(catalog.families(matching: "", limit: 4), ["System", "System Rounded", "System Mono", "System Serif"])
            t.equal(catalog.families(matching: helvetica.uppercased(), limit: 1), [helvetica], "exact family match ranks first")
            t.check(catalog.families(matching: "nEu", limit: 100).contains(neue), "word prefixes are case insensitive")
            let ranked = catalog.families(matching: "hel", limit: 100)
            let familyPrefixes = ranked.filter { $0.lowercased().hasPrefix("hel") }
            t.equal(familyPrefixes, familyPrefixes.sorted(), "equal family-prefix matches have a deterministic name order")
            t.equal(catalog.families(matching: "hel", limit: 2), Array(ranked.prefix(2)), "completion respects its limit")
            for limit in [0, -1] { t.equal(catalog.families(matching: "", limit: limit), []) }
            t.equal(catalog.families(matching: "\0", limit: 10), [])
            let marked = "info { name: \"Fonts\" }\nwidget { Text(\"A\").font(\"Hel|\", 13) }\n"
            let ns = marked as NSString, cursor = ns.range(of: "|").location
            let text = ns.replacingOccurrences(of: "|", with: "")
            let file = DeskFileID(path: "Fonts.desk")
            func completions(fonts: FontCataloging?) -> DeskCompletionList {
                let service = DeskLanguageService(openFile: file, files: [file: text], options: DeskServiceOptions(fonts: fonts))
                let snapshot = service.snapshot
                return snapshot.completions(at: snapshot.index.position(utf16: cursor))
            }
            let list = completions(fonts: catalog)
            t.equal(list.context.place, .fontFamily, "the service requests platform family completions")
            t.check(list.items.contains { $0.label == helvetica }, "the actual installed family reaches completion")
            t.check(!completions(fonts: nil).items.contains { $0.label == helvetica }, "the completion positive depends on the provider")
        }
    }

    private static func fileTests(_ t: AppTestRunner) {
        t.suite("Desk: platform fonts: Data metadata and package inspection preserve native font registration") {
            let inspector = DeskFontFileInspector()
            let uiFont = NSFont.systemFont(ofSize: 13) as CTFont
            let descriptor = CTFontCopyFontDescriptor(uiFont)
            guard let originalURL = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL,
                  originalURL.isFileURL else {
                return t.check(false, "the native system UI font has no readable file URL")
            }
            let url = originalURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix("/System/Library/Fonts/") else {
                return t.check(false, "the UI font URL is outside the authorized system font directory: \(url.path)")
            }
            let beforeFamilies = CTFontManagerCopyAvailableFontFamilyNames() as? [String]
            let beforeNames = CTFontManagerCopyAvailablePostScriptNames() as? [String]
            let generation = Fonts.generation
            guard let beforeFamilies, let beforeNames, !beforeFamilies.isEmpty, !beforeNames.isEmpty else {
                return t.check(false, "native registration state cannot be measured")
            }
            defer {
                t.equal((CTFontManagerCopyAvailableFontFamilyNames() as? [String])?.sorted(), beforeFamilies.sorted(),
                        "inspection does not register or unregister a native family")
                t.equal((CTFontManagerCopyAvailablePostScriptNames() as? [String])?.sorted(), beforeNames.sorted(),
                        "native name matching is unchanged")
                t.equal(Fonts.generation, generation, "inspection does not change the app font registry")
            }
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard !data.isEmpty,
                  let native = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let first = native.first,
                  let family = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String, !family.isEmpty,
                  let inspected = inspector.families(inFontData: data, fileName: "unrelated-name.txt"), !inspected.isEmpty else {
                return t.check(false, "the actual native font data or its metadata cannot be read")
            }
            print("    platform font metadata: \(url.path), \(data.count) bytes, SHA256 \(digest), families \(inspected)")
            t.check(inspected.contains(family), "Data metadata contains the independent original URL descriptor family")
            t.equal(inspector.families(inFontData: data, fileName: "../invented-name.ttf"), inspected,
                    "fileName is descriptive metadata, not a path read or family guess")
            var source = InMemoryPackageSource(files: ["fonts/SystemCopy.ttf": data])
            let loaded = try PackageLoader.load(source, fonts: inspector)
            t.equal(loaded.file(at: "fonts/SystemCopy.ttf")?.fontFamilies, inspected,
                    "the real package loader consumes the native Data inspector")
            for invalid in [Data(), Data([0, 1, 0, 0]), Data("not font data".utf8)] {
                t.equal(inspector.families(inFontData: invalid, fileName: "Helvetica.ttf"), nil,
                        "a plausible file name never turns invalid bytes into a font")
            }
            guard let fixtures = Paths.repositoryFolder("TestSkins") else {
                return t.check(false, "the original invalid repository font control is unavailable")
            }
            let placeholder = try Data(contentsOf: fixtures.appendingPathComponent("Desk/Packages/Harbor/fonts/HarborSans.ttf"))
            t.check(String(decoding: placeholder, as: UTF8.self).contains("not a real font"),
                    "the original Harbor fixture is explicitly placeholder data")
            t.equal(inspector.families(inFontData: placeholder, fileName: "HarborSans.ttf"), nil,
                    "the old fake family cannot become native metadata")
            source.add("fonts/HarborSans.ttf", .file(placeholder))
            let invalidPackage = try PackageLoader.load(source, fonts: inspector)
            t.equal(invalidPackage.file(at: "fonts/HarborSans.ttf")?.fontFamilies, nil,
                    "invalid repository bytes remain unidentified through the real loader")
        }
    }

    private static func installedMappedFamily() -> String? {
        ["Tahoma", "Times", "Courier", "Microsoft Sans Serif", "Arial Nova", "Consolas", "Segoe UI"].first {
            Fonts.installedFamily(named: $0) != nil && Fonts.substitution(for: $0) != nil
        }
    }

    private static func widget(_ family: String) -> String {
        let escaped = family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "info { name: \"Fonts\" }\nwidget { Text(\"A\").font(\"\(escaped)\", 13) }\n"
    }
}
