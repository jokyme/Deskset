// Keeps the app's translations in step with its code. The app's own text goes through `L("English text")`
// (Sources/Deskset/App/Localization.swift); the English text is the key of Localization/Localizable.xcstrings, a
// String Catalog (Xcode opens and edits it; scripts/build-app.sh compiles it into Contents/Resources/<language>.lproj).
// Localization/InfoPlist.xcstrings translates the Info.plist texts macOS shows (permission prompts, document types).
//
//     swift scripts/localization.swift check        exit 1 when the code and the catalogs disagree (CI runs this)
//     swift scripts/localization.swift sync         add the code's new keys to the catalog and drop the ones it no
//                                                   longer uses (their translations go with them)
//     swift scripts/localization.swift report       per language: translated, needing review, missing; and the
//                                                   phrase-like strings left in files the catalog does not cover yet
//     swift scripts/localization.swift export DIR   write DIR/source.tsv (number<TAB>English text) for translators
//     swift scripts/localization.swift import DIR LANGUAGE…
//                                                   read DIR/<language>.tsv (number<TAB>text, numbers from
//                                                   source.tsv) into the catalog as "needs review"; a text marked
//                                                   reviewed ("translated") is kept. A plural key's text is written
//                                                   {one}… {few}… {other}… with the language's CLDR categories.
//     swift scripts/localization.swift --catalog FILE --sources DIR …   (any command) another catalog or source tree
//
// `check` fails when
//   - a key in the code is missing from the catalog, or the catalog keeps a key the code no longer uses (run sync);
//   - L is called with anything but one plain string literal (an interpolation \(…) cannot be looked up: write a
//     format, L("Version %@", version));
//   - a key lacks a text in one of the languages (Localization.languages), or a text's format specifiers (%@, %d, %1$@…)
//     differ from the English key's — a mismatch would crash or print garbage at run time;
//   - a covered file (`covered` below: the files whose every user-visible text is translated) has a phrase-like
//     string literal outside L, other than those listed in scripts/localization-ignore.tsv (file<TAB>literal<TAB>why:
//     identifiers, file names, text that stays English such as log lines);
//   - InfoPlist.xcstrings and the Info.plist that build-app.sh writes disagree (an English text, a permission key with
//     no translation, CFBundleLocalizations).
// Self-test files (names ending in Tests.swift, SelfTest.swift or SelfTests.swift) are skipped: their text is checked
// in English. Exit status: 0 fine, 1 a problem (check), 2 a usage error or an unreadable file.
import Foundation

// MARK: - Settings

var catalogPath = "Localization/Localizable.xcstrings"
var infoPlistCatalogPath = "Localization/InfoPlist.xcstrings"
var ignorePath = "scripts/localization-ignore.tsv"
var sourcesPath = "Sources/Deskset"

/// The files whose user-visible text is all translated (paths below `sourcesPath`). A file joins the list once every
/// text it shows goes through L; from then on `check` keeps it that way.
let covered: [String] = [
    "AppController.swift",
    "App/AboutWindowController.swift",
    "App/AppInstallation.swift",
    "App/AppMaintenancePanel.swift",
    "App/AppRestart.swift",
    "App/AppUpdateController.swift",
    "App/AppUpdateDownload.swift",
    "App/AppUpdateFlow.swift",
    "App/AppUpdateInstaller.swift",
    "App/AppUpdateService.swift",
    "App/CodeEditorRouter.swift",
    "App/CodeEditorSettings.swift",
    "App/FileTrashConfirmation.swift",
    "App/LaunchAtLogin.swift",
    "App/LayoutController.swift",
    "App/LayoutWallpaper.swift",
    "App/MainMenu.swift",
    "App/MetadataEditing.swift",
    "App/ManageModel.swift",
    "App/ManageWindowController.swift",
    "App/NewSkinModel.swift",
    "App/NewSkinWindowController.swift",
    "App/SafeStartController.swift",
    "App/SettingsWindowController.swift",
    "App/SkinInstallFlow.swift", "App/SkinPackagerWindowController.swift",
    "App/WindowGeometry.swift",
]

/// The languages besides English; the same list as Localization.languages in the app (`check` compares them).
let languages = ["ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "he", "hr", "hu", "id", "it", "ja", "ko",
                 "lt", "lv", "ms", "nb", "nl", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sl", "sr", "sr-Latn", "sv",
                 "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]

/// CLDR plural categories of whole numbers per language (the forms a plural text needs).
let pluralCategories: [String: [String]] = {
    var map: [String: [String]] = [:]
    for l in ["ja", "ko", "zh-Hans", "zh-Hant", "th", "vi", "id", "ms"] { map[l] = ["other"] }
    for l in ["bg", "da", "de", "el", "es", "et", "fi", "hu", "it", "nb", "nl", "pt-PT", "sv", "tr", "fr", "pt-BR", "en"] {
        map[l] = ["one", "other"]
    }
    for l in ["cs", "sk"] { map[l] = ["one", "few", "other"] }
    for l in ["hr", "sr", "sr-Latn", "ro"] { map[l] = ["one", "few", "other"] }
    for l in ["pl", "ru", "uk"] { map[l] = ["one", "few", "many", "other"] }
    map["lt"] = ["one", "few", "many", "other"]
    map["lv"] = ["zero", "one", "other"]
    map["sl"] = ["one", "two", "few", "other"]
    map["he"] = ["one", "two", "other"]
    map["ar"] = ["zero", "one", "two", "few", "many", "other"]
    return map
}()

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
func takeOption(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name) else { return nil }
    guard i + 1 < arguments.count else { fail(usage: "\(name) needs a value") }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}
func fail(usage message: String) -> Never {
    FileHandle.standardError.write(Data("localization: \(message)\n".utf8))
    exit(2)
}
if let value = takeOption("--catalog") { catalogPath = value }
if let value = takeOption("--sources") { sourcesPath = value }
let command = arguments.first ?? "check"
let commandArguments = Array(arguments.dropFirst())

// MARK: - Source scanning

struct Use { let key: String; let file: String; let line: Int }
struct Problem { let file: String; let line: Int; let message: String }

func swiftFiles() -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: sourcesPath) else { fail(usage: "cannot read \(sourcesPath)") }
    var files: [String] = []
    for case let path as String in walker where path.hasSuffix(".swift") {
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix("Tests.swift") || name.hasSuffix("SelfTest.swift") || name.hasSuffix("SelfTests.swift") { continue }
        files.append(path)
    }
    return files.sorted()
}

/// A Swift source split into code and the string literals in it (comments dropped). Only what this script needs:
/// plain and multi-line literals with their escapes and interpolations, raw literals (#"…"#), line and block comments.
struct Literal { let text: String; let line: Int; let start: Int; let hasInterpolation: Bool; let isRaw: Bool }

func scan(_ source: String) -> (code: [Character], literals: [Literal]) {
    let chars = Array(source)
    var code: [Character] = []
    var literals: [Literal] = []
    var i = 0, line = 1
    func peek(_ offset: Int) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }
    while i < chars.count {
        let c = chars[i]
        if c == "\n" { line += 1; code.append(c); i += 1; continue }
        if c == "/" && peek(1) == "/" {
            while i < chars.count && chars[i] != "\n" { i += 1 }
            continue
        }
        if c == "/" && peek(1) == "*" {
            var depth = 0
            repeat {
                if chars[i] == "/" && peek(1) == "*" { depth += 1; i += 2; continue }
                if chars[i] == "*" && peek(1) == "/" { depth -= 1; i += 2; continue }
                if chars[i] == "\n" { line += 1 }
                i += 1
            } while depth > 0 && i < chars.count
            continue
        }
        var hashes = 0
        while peek(hashes) == "#" { hashes += 1 }
        if peek(hashes) == "\"" {
            let startLine = line, start = code.count
            i += hashes
            let multi = peek(0) == "\"" && peek(1) == "\"" && peek(2) == "\""
            i += multi ? 3 : 1
            var text = "", interpolated = false
            let closing = String(repeating: "\"", count: multi ? 3 : 1) + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            while i < chars.count {
                if String(chars[i..<min(chars.count, i + closing.count)]) == closing { i += closing.count; break }
                if String(chars[i..<min(chars.count, i + escape.count)]) == escape {
                    i += escape.count
                    guard i < chars.count else { break }
                    let e = chars[i]
                    switch e {
                    case "n": text.append("\n"); i += 1
                    case "t": text.append("\t"); i += 1
                    case "r": text.append("\r"); i += 1
                    case "0": text.append("\0"); i += 1
                    case "\"", "\\", "'": text.append(e); i += 1
                    case "(":
                        // An interpolation: skip to its closing parenthesis (nested parentheses and strings inside are
                        // rare enough in L calls that a depth count is enough here).
                        interpolated = true
                        var depth = 0
                        while i < chars.count {
                            if chars[i] == "(" { depth += 1 }
                            if chars[i] == ")" { depth -= 1; if depth == 0 { i += 1; break } }
                            if chars[i] == "\n" { line += 1 }
                            i += 1
                        }
                        text.append("\u{FFFC}")
                    case "u":
                        // \u{…}
                        if let close = chars[i...].firstIndex(of: "}"),
                           let scalar = UInt32(String(chars[(i + 2)..<close]), radix: 16).flatMap(Unicode.Scalar.init) {
                            text.unicodeScalars.append(scalar)
                            i = close + 1
                        } else { i += 1 }
                    case "\n":
                        // A line continuation in a multi-line literal.
                        line += 1; i += 1
                    default: text.append(e); i += 1
                    }
                    continue
                }
                if chars[i] == "\n" { line += 1 }
                text.append(chars[i])
                i += 1
            }
            if multi {
                // Drop the first and last line breaks and the closing delimiter's indentation.
                var lines = text.components(separatedBy: "\n")
                if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
                let indent = lines.last.map { $0.prefix(while: { $0 == " " }).count } ?? 0
                if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
                text = lines.map { String($0.dropFirst(min(indent, $0.prefix(while: { $0 == " " }).count))) }
                    .joined(separator: "\n")
            }
            literals.append(Literal(text: text, line: startLine, start: start, hasInterpolation: interpolated,
                                    isRaw: hashes > 0))
            code.append(contentsOf: "\"\"")
            continue
        }
        code.append(c)
        i += 1
    }
    return (code, literals)
}

/// Whether a literal reads like text a person sees: two or more words, or a capitalised word (`Cancel`), with letters.
func isPhraseLike(_ text: String) -> Bool {
    let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    guard letters >= 2 else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "Deskset" { return false }
    if text.range(of: "[A-Za-z]{2,}\\S? +\\S", options: .regularExpression) != nil { return true }
    return trimmed == "OK" || trimmed.range(of: "^[A-Z][a-z]+[.…!?:]?$", options: .regularExpression) != nil
}

/// Code before a literal that marks text which is not for the app's UI.
let nonUIContext = try! NSRegularExpression(pattern:
    #"(\bLog\.[a-z]+\w*|\blog\w*|\bfputs|\bprint|\bNSLog|\bassert\w*|\bprecondition\w*|\bfatalError|forKey|\bNSUserInterfaceItemIdentifier|\bidentifier|URL\(\s*string|fileURLWithPath|appendingPathComponent|appendingPathExtension|\bpath|#selector|\bNotification\.Name|\bNSImage\(\s*systemSymbolName|systemSymbolName|\bsymbol\w*|\bdefaults|\bUserDefaults|\bcase|\bcase\s+\w+\s*=|,\s*\w+\s*=(?=\s*$)|\bthrow|Error\w*\(|\.contains|[cC]ompare|\.hasPrefix|\.hasSuffix|==|!=|\bmetadataValue|\bvalue\(for|\bstring\(forKey|\bexecute|\bbang|\bsection)\s*[:(=]?\s*$"#)

func lineText(_ code: [Character], before start: Int) -> String {
    var s = start
    while s > 0 && code[s - 1] != "\n" { s -= 1 }
    return String(code[s..<start])
}

struct Ignore { let file: String; let literal: String }
func loadIgnores() -> [Ignore] {
    guard let text = try? String(contentsOfFile: ignorePath, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { row in
        if row.hasPrefix("#") { return nil }
        let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2 else { return nil }
        return Ignore(file: fields[0], literal: unescapeTSV(fields[1]))
    }
}

func scanSources() -> (uses: [Use], problems: [Problem], uncovered: [Problem], ignoredUsed: Set<String>) {
    var uses: [Use] = [], problems: [Problem] = [], uncovered: [Problem] = []
    let ignores = loadIgnores()
    var ignoredUsed = Set<String>()
    for file in swiftFiles() {
        guard let source = try? String(contentsOfFile: sourcesPath + "/" + file, encoding: .utf8) else {
            fail(usage: "cannot read \(file)")
        }
        let (code, literals) = scan(source)
        let isCovered = covered.contains(file)
        var keyed = Set<Int>()
        // L( followed by a literal: a key. L( followed by anything else: a problem.
        let codeString = String(code)
        let lCalls = try! NSRegularExpression(pattern: #"(?<![\w.])L\("#)
        let ns = codeString as NSString
        for match in lCalls.matches(in: codeString, range: NSRange(location: 0, length: ns.length)) {
            let after = match.range.location + match.range.length
            let declaration = ns.substring(to: match.range.location).hasSuffix("func ")
            if declaration { continue }
            // The Character index of the match (the NSString offsets are UTF-16).
            let prefix = ns.substring(to: after)
            let index = prefix.count
            var j = index
            while j < code.count && (code[j] == " " || code[j] == "\n") { j += 1 }
            let lineNumber = prefix.filter { $0 == "\n" }.count + 1
            guard let literal = literals.first(where: { $0.start == j }) else {
                problems.append(Problem(file: file, line: lineNumber, message: "L needs one string literal as its key"))
                continue
            }
            keyed.insert(literal.start)
            if literal.hasInterpolation {
                problems.append(Problem(file: file, line: literal.line,
                                        message: "L key \"\(literal.text)\" has an interpolation: use a format, L(\"… %@\", value)"))
            } else if literal.isRaw {
                problems.append(Problem(file: file, line: literal.line, message: "L key must be a plain literal, not #\"…\"#"))
            } else {
                uses.append(Use(key: literal.text, file: file, line: literal.line))
            }
        }
        // Phrase-like literals outside L.
        for literal in literals where !keyed.contains(literal.start) {
            let shown = literal.text.replacingOccurrences(of: "\u{FFFC}", with: "")
            guard isPhraseLike(shown) else { continue }
            let before = lineText(code, before: literal.start)
            if nonUIContext.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil {
                continue
            }
            if let ignore = ignores.first(where: { $0.file == file && $0.literal == literal.text }) {
                ignoredUsed.insert(ignore.file + "\t" + ignore.literal)
                continue
            }
            let problem = Problem(file: file, line: literal.line, message: "text outside L: \"\(literal.text)\"")
            if isCovered { problems.append(problem) } else { uncovered.append(problem) }
        }
    }
    for ignore in ignores where !ignoredUsed.contains(ignore.file + "\t" + ignore.literal) {
        problems.append(Problem(file: ignorePath, line: 0,
                                message: "ignore entry no longer matches: \(ignore.file) \"\(ignore.literal)\""))
    }
    return (uses, problems, uncovered, ignoredUsed)
}

// MARK: - Catalog

func loadCatalog(_ path: String) -> NSMutableDictionary {
    guard let data = FileManager.default.contents(atPath: path) else {
        return ["sourceLanguage": "en", "strings": NSMutableDictionary(), "version": "1.0"] as NSMutableDictionary
    }
    guard let object = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers]),
          let catalog = object as? NSMutableDictionary else { fail(usage: "\(path) is not a String Catalog") }
    if catalog["strings"] == nil { catalog["strings"] = NSMutableDictionary() }
    return catalog
}

func saveCatalog(_ catalog: NSDictionary, to path: String) {
    do {
        var data = try JSONSerialization.data(withJSONObject: catalog,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(contentsOf: Array("\n".utf8))
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fail(usage: "cannot write \(path): \(error.localizedDescription)")
    }
}

func strings(_ catalog: NSDictionary) -> NSMutableDictionary { catalog["strings"] as! NSMutableDictionary }

/// The texts of one language for a key: ["": text] for a plain text, [category: text] for plural variations.
func texts(_ entry: NSDictionary?, _ language: String) -> [String: (value: String, state: String)] {
    guard let localization = (entry?["localizations"] as? NSDictionary)?[language] as? NSDictionary else { return [:] }
    if let unit = localization["stringUnit"] as? NSDictionary, let value = unit["value"] as? String {
        return ["": (value, unit["state"] as? String ?? "")]
    }
    var result: [String: (value: String, state: String)] = [:]
    if let plural = (localization["variations"] as? NSDictionary)?["plural"] as? NSDictionary {
        for case let (category as String, form as NSDictionary) in plural {
            if let unit = form["stringUnit"] as? NSDictionary, let value = unit["value"] as? String {
                result[category] = (value, unit["state"] as? String ?? "")
            }
        }
    }
    return result
}

let specifier = try! NSRegularExpression(pattern:
    #"%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])"#)

/// A text's format specifiers in argument order ("%1$@" and "%@" both count as "@" for the first argument).
func specifiers(_ text: String) -> [String] {
    let ns = text as NSString
    var next = 1
    var found: [Int: String] = [:]
    for m in specifier.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let conversion = ns.substring(with: m.range(at: 3))
        if conversion == "%" { continue }
        let length = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
        var position = next
        if m.range(at: 1).location != NSNotFound { position = Int(ns.substring(with: m.range(at: 1))) ?? next }
        else { next += 1 }
        let kind = conversion == "@" ? "@" : (["f", "F", "e", "E", "g", "G", "a", "A"].contains(conversion) ? "f" : "d")
        found[position] = kind + (kind == "d" ? length : "")
    }
    return found.keys.sorted().map { found[$0]! }
}

func catalogProblems(_ catalog: NSDictionary, uses: [Use], requireAllLanguages: Bool) -> [Problem] {
    var problems: [Problem] = []
    let entries = strings(catalog)
    let usedKeys = Set(uses.map(\.key))
    for use in uses where entries[use.key] == nil {
        problems.append(Problem(file: use.file, line: use.line,
                                message: "\"\(use.key)\" is not in \(catalogPath) (run: swift scripts/localization.swift sync)"))
    }
    for case let key as String in entries.allKeys where !usedKeys.contains(key) {
        problems.append(Problem(file: catalogPath, line: 0, message: "\"\(key)\" is no longer used (run sync)"))
    }
    for case let (key as String, entry as NSDictionary) in entries {
        let english = texts(entry, "en")
        let expected = specifiers(english["other"]?.value ?? key)
        for language in languages + ["en"] {
            let forms = texts(entry, language)
            if forms.isEmpty {
                if language != "en" && requireAllLanguages {
                    problems.append(Problem(file: catalogPath, line: 0, message: "\"\(key)\" has no \(language) text"))
                }
                continue
            }
            if forms[""] == nil {
                // Plural variations: every category of the language, each with the key's specifiers (a form may leave
                // the number out, as "one" often does, but not add or change one).
                let needed = pluralCategories[language] ?? ["one", "other"]
                for category in needed where forms[category] == nil {
                    problems.append(Problem(file: catalogPath, line: 0,
                                            message: "\"\(key)\" \(language) lacks the plural form \(category)"))
                }
                for (category, form) in forms {
                    let found = specifiers(form.value)
                    if category == "other" ? found != expected : !isSubsequence(found, of: expected) {
                        problems.append(Problem(file: catalogPath, line: 0,
                                                message: "\"\(key)\" \(language) \(category): format \(found) ≠ \(expected)"))
                    }
                }
            } else if let text = forms[""], specifiers(text.value) != expected {
                problems.append(Problem(file: catalogPath, line: 0,
                                        message: "\"\(key)\" \(language): format \(specifiers(text.value)) ≠ \(expected)"))
            } else if let text = forms[""], text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append(Problem(file: catalogPath, line: 0, message: "\"\(key)\" \(language) text is empty"))
            }
        }
    }
    return problems
}

func isSubsequence(_ a: [String], of b: [String]) -> Bool {
    // Positions matter: a form without the number keeps the other arguments' kinds in order.
    a.isEmpty || a == b || (a.count < b.count && b.dropFirst(b.count - a.count).elementsEqual(a)) || b.starts(with: a)
}

// MARK: - Info.plist

func infoPlistProblems() -> [Problem] {
    var problems: [Problem] = []
    let temporary = NSTemporaryDirectory() + "deskset-localization-\(getpid()).plist"
    defer { try? FileManager.default.removeItem(atPath: temporary) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["scripts/build-app.sh", "--plist", temporary]
    process.standardOutput = FileHandle.nullDevice
    do { try process.run() } catch { fail(usage: "cannot run build-app.sh: \(error)") }
    process.waitUntilExit()
    guard process.terminationStatus == 0, let data = FileManager.default.contents(atPath: temporary),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return [Problem(file: "scripts/build-app.sh", line: 0, message: "--plist did not write a readable Info.plist")]
    }
    let catalog = loadCatalog(infoPlistCatalogPath)
    let entries = strings(catalog)
    let localizations = (plist["CFBundleLocalizations"] as? [String]) ?? []
    if Set(localizations) != Set(["en"] + languages) {
        problems.append(Problem(file: "scripts/build-app.sh", line: 0,
                                message: "CFBundleLocalizations \(localizations) ≠ en + \(languages.count) languages"))
    }
    // Every text macOS shows from the plist: permission prompts, the copyright line, document type names.
    var shown: [String: String] = [:]
    for (key, value) in plist {
        if let text = value as? String, key.hasSuffix("UsageDescription") || key == "NSHumanReadableCopyright" {
            shown[key] = text
        }
    }
    for type in (plist["CFBundleDocumentTypes"] as? [[String: Any]]) ?? [] {
        if let name = type["CFBundleTypeName"] as? String { shown[name] = name }
    }
    for type in (plist["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? [] {
        if let name = type["UTTypeDescription"] as? String { shown[name] = name }
    }
    for (key, english) in shown {
        guard let entry = entries[key] as? NSDictionary else {
            problems.append(Problem(file: infoPlistCatalogPath, line: 0, message: "\"\(key)\" is missing"))
            continue
        }
        let catalogEnglish = texts(entry, "en")[""]?.value ?? key
        if catalogEnglish != english {
            problems.append(Problem(file: infoPlistCatalogPath, line: 0,
                                    message: "\"\(key)\": the English text differs from build-app.sh's Info.plist"))
        }
        for language in languages where texts(entry, language).isEmpty {
            problems.append(Problem(file: infoPlistCatalogPath, line: 0, message: "\"\(key)\" has no \(language) text"))
        }
    }
    for case let key as String in entries.allKeys where shown[key] == nil {
        problems.append(Problem(file: infoPlistCatalogPath, line: 0, message: "\"\(key)\" is not in the Info.plist"))
    }
    return problems
}

func languageListProblems() -> [Problem] {
    let file = sourcesPath + "/App/Localization.swift"
    guard let source = try? String(contentsOfFile: file, encoding: .utf8),
          let start = source.range(of: "static let languages = ["),
          let end = source[start.upperBound...].firstIndex(of: "]") else {
        return [Problem(file: file, line: 0, message: "Localization.languages not found")]
    }
    let listed = source[start.upperBound..<end].components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"")) }.filter { !$0.isEmpty }
    return listed == languages ? []
        : [Problem(file: file, line: 0, message: "Localization.languages differs from scripts/localization.swift")]
}

// MARK: - TSV

func escapeTSV(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\n", with: "\\n")
}
func unescapeTSV(_ s: String) -> String {
    var out = "", escaping = false
    for c in s {
        if escaping {
            switch c { case "t": out.append("\t"); case "n": out.append("\n"); default: out.append(c) }
            escaping = false
        } else if c == "\\" { escaping = true } else { out.append(c) }
    }
    return out
}

// MARK: - Commands

func printProblems(_ problems: [Problem]) {
    for p in problems { print(p.line > 0 ? "\(p.file):\(p.line): \(p.message)" : "\(p.file): \(p.message)") }
}

switch command {
case "check":
    let scanned = scanSources()
    let catalog = loadCatalog(catalogPath)
    var problems = scanned.problems + catalogProblems(catalog, uses: scanned.uses, requireAllLanguages: true)
    problems += infoPlistProblems() + languageListProblems()
    printProblems(problems)
    let keys = Set(scanned.uses.map(\.key)).count
    print("\(keys) keys in \(covered.count) covered files, \(languages.count) languages; \(problems.count) problems; "
          + "\(scanned.uncovered.count) phrase-like strings in files not covered yet")
    exit(problems.isEmpty ? 0 : 1)

case "sync":
    let scanned = scanSources()
    let catalog = loadCatalog(catalogPath)
    let entries = strings(catalog)
    let used = Set(scanned.uses.map(\.key))
    var added = 0, removed = 0
    for key in used where entries[key] == nil {
        entries[key] = ["extractionState": "manual"] as NSMutableDictionary
        added += 1
    }
    for case let key as String in entries.allKeys where !used.contains(key) {
        entries.removeObject(forKey: key)
        removed += 1
    }
    saveCatalog(catalog, to: catalogPath)
    print("\(catalogPath): \(added) added, \(removed) removed, \(entries.count) keys")

case "report":
    let scanned = scanSources()
    let catalog = loadCatalog(catalogPath)
    let entries = strings(catalog)
    for language in languages {
        var reviewed = 0, review = 0, missing = 0
        for case let entry as NSDictionary in entries.allValues {
            let forms = texts(entry, language)
            if forms.isEmpty { missing += 1 } else if forms.values.allSatisfy({ $0.state == "translated" }) { reviewed += 1 }
            else { review += 1 }
        }
        print("\(language.padding(toLength: 8, withPad: " ", startingAt: 0)) reviewed \(reviewed), needs review \(review), missing \(missing)")
    }
    var perFile: [String: Int] = [:]
    for p in scanned.uncovered { perFile[p.file, default: 0] += 1 }
    print("\nPhrase-like strings outside L in files not covered yet:")
    for (file, count) in perFile.sorted(by: { $0.value > $1.value }) { print("  \(count)\t\(file)") }

case "export":
    guard let directory = commandArguments.first else { fail(usage: "export needs a directory") }
    let entries = strings(loadCatalog(catalogPath))
    let keys = (entries.allKeys as! [String]).sorted()
    var lines: [String] = []
    for (n, key) in keys.enumerated() {
        let plural = !(texts(entries[key] as? NSDictionary, "en")["other"]?.value ?? "").isEmpty
        // The English text: the key, or the English value of a key that names its text (InfoPlist's NS…Description).
        let english = texts(entries[key] as? NSDictionary, "en")[""]?.value ?? key
        lines.append("\(n + 1)\t\(escapeTSV(english))" + (plural ? "\tplural" : ""))
    }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try! (lines.joined(separator: "\n") + "\n").write(toFile: directory + "/source.tsv", atomically: true, encoding: .utf8)
    print("wrote \(directory)/source.tsv (\(keys.count) keys)")

case "import":
    guard commandArguments.count >= 2 else { fail(usage: "import needs a directory and languages") }
    let directory = commandArguments[0]
    guard let source = try? String(contentsOfFile: directory + "/source.tsv", encoding: .utf8) else {
        fail(usage: "cannot read \(directory)/source.tsv")
    }
    let catalog = loadCatalog(catalogPath)
    let entries = strings(catalog)
    // Numbers count the catalog's keys in export order; source.tsv's English must still match (no key was added or
    // changed since the export).
    let sortedKeys = (entries.allKeys as! [String]).sorted()
    var keyByNumber: [Int: String] = [:]
    for row in source.split(separator: "\n") {
        let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 2, let n = Int(fields[0]) else { continue }
        guard n >= 1, n <= sortedKeys.count,
              unescapeTSV(String(fields[1])) == (texts(entries[sortedKeys[n - 1]] as? NSDictionary, "en")[""]?.value
                                                 ?? sortedKeys[n - 1]) else {
            fail(usage: "\(directory)/source.tsv no longer matches the catalog (line \(n)): export again")
        }
        keyByNumber[n] = sortedKeys[n - 1]
    }
    let categoryPattern = try! NSRegularExpression(pattern: #"\{(zero|one|two|few|many|other)\}"#)
    var failed = false
    for language in commandArguments.dropFirst() {
        guard let text = try? String(contentsOfFile: directory + "/\(language).tsv", encoding: .utf8) else {
            fail(usage: "cannot read \(directory)/\(language).tsv")
        }
        var imported = 0, kept = 0
        for row in text.split(separator: "\n") {
            let fields = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let n = Int(fields[0].trimmingCharacters(in: .whitespaces)),
                  let key = keyByNumber[n], let entry = entries[key] as? NSMutableDictionary else {
                print("\(language).tsv: skipped line \(row.prefix(40))")
                failed = true
                continue
            }
            let value = unescapeTSV(String(fields[1]))
            let existing = texts(entry, language)
            if !existing.isEmpty && existing.values.allSatisfy({ $0.state == "translated" }) { kept += 1; continue }
            let localizations = (entry["localizations"] as? NSMutableDictionary) ?? NSMutableDictionary()
            entry["localizations"] = localizations
            let ns = value as NSString
            let marks = categoryPattern.matches(in: value, range: NSRange(location: 0, length: ns.length))
            if marks.isEmpty {
                localizations[language] = ["stringUnit": ["state": "needs_review", "value": value]]
            } else {
                let plural = NSMutableDictionary()
                for (index, mark) in marks.enumerated() {
                    let start = mark.range.location + mark.range.length
                    let end = index + 1 < marks.count ? marks[index + 1].range.location : ns.length
                    let form = ns.substring(with: NSRange(location: start, length: end - start))
                        .trimmingCharacters(in: .whitespaces)
                    plural[ns.substring(with: mark.range(at: 1))] = ["stringUnit": ["state": "needs_review", "value": form]]
                }
                localizations[language] = ["variations": ["plural": plural]]
            }
            imported += 1
        }
        print("\(language): \(imported) imported as needs review, \(kept) reviewed texts kept")
    }
    saveCatalog(catalog, to: catalogPath)
    exit(failed ? 1 : 0)

default:
    fail(usage: "unknown command \(command) (check, sync, report, export, import)")
}
