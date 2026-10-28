// Keeps the app's translations in step with its code. The app's own text goes through `L("English text")`
// (Sources/Deskset/App/Localization.swift); the English text is the key. Every language has its own folder,
// Localization/<language>.lproj, as macOS expects them in the app bundle (scripts/build-app.sh copies them):
//   Localizable.strings      "English text" = "translation"; each entry has a comment saying where the text appears
//   Localizable.stringsdict  the texts that change with a number (one file, two files…), in the language's plural forms
//   InfoPlist.strings        the Info.plist texts macOS shows (permission prompts, the copyright line, document types)
// en.lproj is the source: its Localizable.strings lists every key in the order the app shows them, grouped by window,
// with the comments; `sync` writes it from the code and gives every language file the same order and comments.
// A comment line that starts with "Note:" is written by hand (what a placeholder stands for, where a short text sits)
// and survives `sync`.
//
//     swift scripts/localization.swift check        exit 1 when the code and the language files disagree (CI runs it)
//     swift scripts/localization.swift sync         write en.lproj from the code; re-order every language file and
//                                                   drop the keys the code no longer uses
//     swift scripts/localization.swift report       per language: texts present and missing; and the phrase-like
//                                                   strings left in files not covered yet
//     swift scripts/localization.swift export DIR [--table InfoPlist]
//                                                   write DIR/source.tsv: number<TAB>English<TAB>plural?<TAB>context
//     swift scripts/localization.swift import DIR LANGUAGE… [--table InfoPlist]
//                                                   read DIR/<language>.tsv (number<TAB>text, numbers from
//                                                   source.tsv) into that language's files; a plural text is written
//                                                   {one}… {few}… {other}… with the language's CLDR categories
//     --localization DIR, --sources DIR             (any command) another Localization folder or source tree
//
// `check` fails when
//   - a key in the code is missing from en.lproj, or en.lproj keeps a key the code no longer uses (run sync);
//   - L is called with anything but one plain string literal (an interpolation \(…) cannot be looked up: write a
//     format, L("Version %@", version));
//   - a language lacks a text, keeps one for a key that is gone, or a text's format specifiers (%@, %d, %1$@…) differ
//     from the English — a mismatch would crash or print garbage at run time; a plural text lacks one of its forms;
//   - a file is not one macOS can read, or the language folders differ from Localization.languages;
//   - a covered file (`covered` below: the files whose every user-visible text is translated) has a phrase-like
//     string literal outside L, other than those listed in scripts/localization-ignore.tsv (file<TAB>literal<TAB>why:
//     identifiers, file names, text that stays English such as log lines);
//   - InfoPlist.strings and the Info.plist that build-app.sh writes disagree (an English text, a key with no
//     translation, CFBundleLocalizations).
// Self-test files (names ending in Tests.swift, SelfTest.swift or SelfTests.swift) are skipped: their text is checked
// in English. Exit status: 0 fine, 1 a problem (check), 2 a usage error or an unreadable file.
import Foundation

// MARK: - Settings

var localizationPath = "Localization"
/// Where the translations are made (each language file says so in its header).
let weblateURL = "https://hosted.weblate.org/projects/deskset/"
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
if let value = takeOption("--localization") { localizationPath = value }
let table = takeOption("--table") ?? "Localizable"
if let value = takeOption("--sources") { sourcesPath = value }
let command = arguments.first ?? "check"
let commandArguments = Array(arguments.dropFirst())

// MARK: - Source scanning

struct Use { let key: String; let file: String; let line: Int; let kind: String }
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
                let before = String(ns.substring(to: match.range.location).split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
                uses.append(Use(key: literal.text, file: file, line: literal.line, kind: kind(before: before)))
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

// MARK: - Where a text appears

/// The windows the covered files draw, in the order en.lproj lists them (a file not named here comes last, by name).
let areas: [(file: String, name: String)] = [
    ("App/MainMenu.swift", "Main menu"),
    ("AppController.swift", "Menu bar menu, skin menus and update alerts"),
    ("App/WindowGeometry.swift", "Skin settings (Manage window and skin menu)"),
    ("App/ManageWindowController.swift", "Manage window"),
    ("App/ManageModel.swift", "Manage window"),
    ("App/MetadataEditing.swift", "Manage window"),
    ("App/LayoutController.swift", "Layouts"),
    ("App/LayoutWallpaper.swift", "Layouts"),
    ("App/SettingsWindowController.swift", "Settings window"),
    ("App/CodeEditorSettings.swift", "Settings window"),
    ("App/CodeEditorRouter.swift", "Code editor"),
    ("App/AboutWindowController.swift", "About window"),
    ("App/NewSkinWindowController.swift", "New Skin window"),
    ("App/NewSkinModel.swift", "New Skin window"),
    ("App/SkinInstallFlow.swift", "Skin installer"),
    ("App/SkinPackagerWindowController.swift", "Skin Packager window"),
    ("App/FileTrashConfirmation.swift", "Move to Trash confirmation"),
    ("App/LaunchAtLogin.swift", "Launch at Login"),
    ("App/SafeStartController.swift", "Safe Start"),
    ("App/AppUpdateController.swift", "App updates"),
    ("App/AppUpdateFlow.swift", "App updates"),
    ("App/AppUpdateService.swift", "App updates"),
    ("App/AppUpdateDownload.swift", "App updates"),
    ("App/AppUpdateInstaller.swift", "App updates"),
    ("App/AppInstallation.swift", "Installing Deskset in Applications"),
    ("App/AppMaintenancePanel.swift", "Install and update panels"),
    ("App/AppRestart.swift", "Restarting Deskset"),
]

func area(of file: String) -> (order: Int, name: String) {
    if let i = areas.firstIndex(where: { $0.file == file }) { return (i, areas[i].name) }
    return (areas.count, (file as NSString).deletingPathExtension.components(separatedBy: "/").last ?? file)
}

/// What a text is on screen, from the code before `L(` on its line ("text" when the code does not say).
func kind(before code: String) -> String {
    let rules: [(String, String)] = [
        (#"addButton\(withTitle:\s*$|(NSButton|ActionButton|Button)\(title:\s*$|\.prompt\s*=\s*$|primary\.title\s*=\s*$"#,
         "button"),
        (#"checkboxWithTitle:\s*$"#, "checkbox"),
        (#"(\bitem|findItem)\(\s*$|addItem\(withTitle:\s*$|NSMenuItem\(title:\s*$"#, "menu item"),
        (#"NSMenu\(title:\s*$"#, "menu title"),
        (#"messageText\s*=\s*$|\balert\(\s*$"#, "alert title"),
        (#"informativeText\s*=\s*$|\balert\(L\(.*\),\s*$|panel\.message\s*=\s*$"#, "alert or dialog message"),
        (#"[tT]oolTip\s*[:=]\s*$"#, "tooltip"),
        (#"accessibilityDescription:\s*$|setAccessibility\w*\(\s*$"#, "VoiceOver description"),
        (#"placeholderString\s*=\s*$"#, "placeholder in an empty field"),
        (#"(window|w)\.title\s*=\s*$|makeWindow\(title:\s*$"#, "window title"),
        (#"column\.title\s*=\s*$"#, "column heading"),
        (#"heading\.stringValue\s*=\s*$"#, "heading"),
        (#"(labelWithString:|formLabel\(|\blabel\(|leftLabel:)\s*$"#, "label"),
        (#"(footnote\.stringValue\s*=|bottomNote:|note\()\s*$"#, "note under a panel or list"),
        (#"(detail|statusLabel|status)\S*\s*[:=]\s*$|rightMeta:\s*$"#, "status or description line"),
        (#"\breturn\s*$|throw .*\(\s*$"#, "message (an error or a status)"),
    ]
    for (pattern, name) in rules where code.range(of: pattern, options: .regularExpression) != nil { return name }
    return "text"
}

/// "Area: kind; Area: kind." for a key's uses, in area order.
func context(_ uses: [Use]) -> String {
    var seen: [(Int, String, String)] = []
    for use in uses {
        let a = area(of: use.file)
        if !seen.contains(where: { $0.1 == a.name && $0.2 == use.kind }) { seen.append((a.order, a.name, use.kind)) }
    }
    seen.sort { $0.0 < $1.0 }
    var byArea: [(String, [String])] = []
    for (_, name, kind) in seen {
        if let i = byArea.firstIndex(where: { $0.0 == name }) { byArea[i].1.append(kind) } else { byArea.append((name, [kind])) }
    }
    return byArea.map { "\($0.0): \($0.1.joined(separator: ", "))" }.joined(separator: "; ") + "."
}

// MARK: - Language files

struct Entry { var key: String; var value: String; var comment: String; var section: String = "" }
struct StringsFile { var status: String?; var entries: [Entry] }

func lproj(_ language: String) -> String { "\(localizationPath)/\(language).lproj" }
func stringsPath(_ language: String, _ table: String) -> String { "\(lproj(language))/\(table).strings" }
func pluralPath(_ language: String) -> String { "\(lproj(language))/Localizable.stringsdict" }

/// Reads a .strings file as this script writes it: `/* comment */` before `"key" = "value";`, `//` lines for
/// section titles and the status line. nil when there is no file.
func readStrings(_ path: String) -> StringsFile? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let c = Array(text)
    var i = 0, comment = "", status: String?, entries: [Entry] = []
    func stop(_ why: String) -> Never {
        let line = c[..<min(i, c.count)].filter { $0 == "\n" }.count + 1
        fail(usage: "\(path):\(line): \(why)")
    }
    func skipSpace() { while i < c.count && c[i].isWhitespace { i += 1 } }
    func quoted() -> String {
        guard i < c.count, c[i] == "\"" else { stop("expected a quoted string") }
        i += 1
        var out = ""
        while i < c.count && c[i] != "\"" {
            if c[i] == "\\" {
                i += 1
                guard i < c.count else { stop("unfinished escape") }
                switch c[i] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "U", "u":
                    let hex = String(c[(i + 1)..<min(i + 5, c.count)])
                    guard let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) else { stop("bad \\U escape") }
                    out.unicodeScalars.append(s)
                    i += 4
                default: out.append(c[i])
                }
            } else { out.append(c[i]) }
            i += 1
        }
        guard i < c.count else { stop("unfinished string") }
        i += 1
        return out
    }
    while true {
        skipSpace()
        guard i < c.count else { break }
        if c[i] == "/" && i + 1 < c.count && c[i + 1] == "/" {
            var line = ""
            while i < c.count && c[i] != "\n" { line.append(c[i]); i += 1 }
            if line.hasPrefix("// Status:") { status = String(line.dropFirst("// Status:".count)).trimmingCharacters(in: .whitespaces) }
        } else if c[i] == "/" && i + 1 < c.count && c[i + 1] == "*" {
            i += 2
            var body = ""
            while i + 1 < c.count && !(c[i] == "*" && c[i + 1] == "/") { body.append(c[i]); i += 1 }
            guard i + 1 < c.count else { stop("unfinished comment") }
            i += 2
            comment = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        } else if c[i] == "\"" || c[i].isLetter {
            var key = ""
            if c[i] == "\"" { key = quoted() } else {
                while i < c.count && (c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == ".") { key.append(c[i]); i += 1 }
            }
            skipSpace()
            guard i < c.count, c[i] == "=" else { stop("expected =") }
            i += 1
            skipSpace()
            let value = quoted()
            skipSpace()
            guard i < c.count, c[i] == ";" else { stop("expected ;") }
            i += 1
            entries.append(Entry(key: key, value: value, comment: comment))
            comment = ""
        } else {
            stop("unexpected \"\(c[i])\"")
        }
    }
    return StringsFile(status: status, entries: entries)
}

/// A key as Weblate's .strings writer puts it: NS…Description keys (Info.plist) bare, every other key quoted.
func keyText(_ key: String) -> String {
    key.range(of: "^NS.*Description$", options: .regularExpression) != nil ? key : quote(key)
}

func quote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
}

func languageName(_ language: String) -> String {
    Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
}

func writeStrings(_ file: StringsFile, language: String, table: String) {
    var out = "// Deskset — \(table == "InfoPlist" ? "Info.plist texts" : "the app's own text"), "
        + "\(language == "en" ? "English (the source)" : languageName(language)).\n"
    if language == "en" {
        out += "// The keys are the app's English text. `swift scripts/localization.swift sync` writes this file from the code.\n"
    } else {
        out += "// Translated on Weblate: \(weblateURL)\n"
        out += "// Order and comments follow en.lproj (`swift scripts/localization.swift sync`).\n"
    }
    if let status = file.status { out += "// Status: \(status)\n" }
    var section = ""
    for entry in file.entries {
        if !entry.section.isEmpty && entry.section != section {
            section = entry.section
            out += "\n// MARK: \(section)\n"
        }
        out += "\n"
        if !entry.comment.isEmpty { out += "/* " + entry.comment.replacingOccurrences(of: "\n", with: "\n   ") + " */\n" }
        out += "\(keyText(entry.key)) = \(quote(entry.value));\n"
    }
    let path = stringsPath(language, table)
    try? FileManager.default.createDirectory(atPath: lproj(language), withIntermediateDirectories: true)
    do { try out.write(toFile: path, atomically: true, encoding: .utf8) } catch { fail(usage: "cannot write \(path)") }
}

func readPlurals(_ language: String) -> [String: [String: String]] {
    guard let data = FileManager.default.contents(atPath: pluralPath(language)) else { return [:] }
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        fail(usage: "\(pluralPath(language)) is not a property list")
    }
    var result: [String: [String: String]] = [:]
    for (key, value) in plist {
        guard let rule = (value as? [String: Any])?["value"] as? [String: Any] else { continue }
        var forms: [String: String] = [:]
        for (category, text) in rule where !category.hasPrefix("NSString") { forms[category] = text as? String }
        result[key] = forms
    }
    return result
}

/// The CLDR order of plural forms, the order Weblate writes them in.
let pluralOrder = ["zero", "one", "two", "few", "many", "other"]

/// Writes a .stringsdict byte for byte as Weblate does (Python's plistlib: tabs, keys in this order, forms in CLDR
/// order), so that a file Weblate saved and one this script wrote only differ where a text does.
func writePlurals(_ plurals: [String: [String: String]], language: String) {
    let path = pluralPath(language)
    if plurals.isEmpty { try? FileManager.default.removeItem(atPath: path); return }
    func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    var out = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>

    """
    for key in plurals.keys.sorted() {
        // The value type of the number the forms choose by: the key's first integer specifier (lld for %lld).
        let ns = key as NSString
        let m = specifier.matches(in: key, range: NSRange(location: 0, length: ns.length))
            .first { ns.substring(with: $0.range(at: 3)) != "@" && ns.substring(with: $0.range(at: 3)) != "%" }
        let type = m.map { ($0.range(at: 2).location == NSNotFound ? "" : ns.substring(with: $0.range(at: 2)))
            + ns.substring(with: $0.range(at: 3)) } ?? "lld"
        out += "\t<key>\(xml(key))</key>\n\t<dict>\n"
        out += "\t\t<key>NSStringLocalizedFormatKey</key>\n\t\t<string>%#@value@</string>\n"
        out += "\t\t<key>value</key>\n\t\t<dict>\n"
        out += "\t\t\t<key>NSStringFormatSpecTypeKey</key>\n\t\t\t<string>NSStringPluralRuleType</string>\n"
        out += "\t\t\t<key>NSStringFormatValueTypeKey</key>\n\t\t\t<string>\(type)</string>\n"
        let forms = plurals[key]!
        for category in pluralOrder where !(forms[category] ?? "").isEmpty {
            out += "\t\t\t<key>\(category)</key>\n\t\t\t<string>\(xml(forms[category]!))</string>\n"
        }
        out += "\t\t</dict>\n\t</dict>\n"
    }
    out += "</dict>\n</plist>\n"
    do {
        try FileManager.default.createDirectory(atPath: lproj(language), withIntermediateDirectories: true)
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    } catch { fail(usage: "cannot write \(path)") }
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

func isSubsequence(_ a: [String], of b: [String]) -> Bool {
    // Positions matter: a form without the number keeps the other arguments' kinds in order.
    a.isEmpty || a == b || (a.count < b.count && b.dropFirst(b.count - a.count).elementsEqual(a)) || b.starts(with: a)
}

/// The English a key shows: the key without its `|context` (`Edit|menu` shows "Edit").
func shownText(_ key: String) -> String {
    key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
}

/// en.lproj's entries for the code's keys: first use first (in area order), comments made from every use, the hand-
/// written "Note:" lines of the existing file kept.
func englishEntries(_ uses: [Use], existing: StringsFile?, plurals: Set<String>) -> [Entry] {
    var byKey: [String: [Use]] = [:]
    for use in uses { byKey[use.key, default: []].append(use) }
    let notes = Dictionary((existing?.entries ?? []).map { entry in
        (entry.key, entry.comment.split(separator: "\n").filter { $0.hasPrefix("Note:") }.joined(separator: "\n"))
    }, uniquingKeysWith: { a, _ in a })
    let ordered = byKey.keys.sorted { a, b in
        let ua = byKey[a]!.min { (area(of: $0.file).order, $0.file, $0.line) < (area(of: $1.file).order, $1.file, $1.line) }!
        let ub = byKey[b]!.min { (area(of: $0.file).order, $0.file, $0.line) < (area(of: $1.file).order, $1.file, $1.line) }!
        return (area(of: ua.file).order, ua.file, ua.line, a) < (area(of: ub.file).order, ub.file, ub.line, b)
    }
    return ordered.map { key in
        let uses = byKey[key]!
        let first = uses.min { (area(of: $0.file).order, $0.file, $0.line) < (area(of: $1.file).order, $1.file, $1.line) }!
        var comment = context(uses)
        if plurals.contains(key) { comment += " Plural forms: Localizable.stringsdict." }
        if let note = notes[key], !note.isEmpty { comment += "\n" + note }
        return Entry(key: key, value: shownText(key), comment: comment, section: area(of: first.file).name)
    }
}

/// A language's entries in en's order and with en's comments; a key the language lacks is left out.
func reordered(_ file: StringsFile?, like english: [Entry], skipping: Set<String> = []) -> StringsFile {
    let values = Dictionary((file?.entries ?? []).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
    return StringsFile(status: file?.status, entries: english.compactMap { e in
        guard !skipping.contains(e.key), let value = values[e.key] else { return nil }
        return Entry(key: e.key, value: value, comment: e.comment, section: e.section)
    })
}

/// Whether macOS reads the file as this script does (the old-style plist parser behind Bundle).
func appleReads(_ path: String, _ file: StringsFile) -> Bool {
    guard let data = FileManager.default.contents(atPath: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
        return false
    }
    return plist == Dictionary(file.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
}

func textProblems(_ key: String, _ language: String, _ value: String, expected: [String], file: String) -> [Problem] {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return [Problem(file: file, line: 0, message: "\"\(key)\" \(language) text is empty")]
    }
    let found = specifiers(value)
    return found == expected ? []
        : [Problem(file: file, line: 0, message: "\"\(key)\": format \(found) ≠ \(expected)")]
}

func languageFileProblems(uses: [Use]) -> [Problem] {
    var problems: [Problem] = []
    let enPath = stringsPath("en", "Localizable")
    guard let english = readStrings(enPath) else { return [Problem(file: enPath, line: 0, message: "missing")] }
    if !appleReads(enPath, english) { problems.append(Problem(file: enPath, line: 0, message: "macOS cannot read it")) }
    let englishKeys = english.entries.map(\.key)
    let englishPlurals = readPlurals("en")
    let allKeys = Set(englishKeys).union(englishPlurals.keys)
    let used = Set(uses.map(\.key))
    for use in uses where !allKeys.contains(use.key) {
        problems.append(Problem(file: use.file, line: use.line,
                                message: "\"\(use.key)\" is not in \(enPath) (run: swift scripts/localization.swift sync)"))
    }
    for key in englishKeys where !used.contains(key) {
        problems.append(Problem(file: enPath, line: 0, message: "\"\(key)\" is no longer used (run sync)"))
    }
    for e in english.entries where e.value != shownText(e.key) {
        problems.append(Problem(file: enPath, line: 0, message: "\"\(e.key)\": the English text must equal its key"))
    }
    for key in englishPlurals.keys where !used.contains(key) {
        problems.append(Problem(file: pluralPath("en"), line: 0, message: "\"\(key)\" is no longer used"))
    }
    for key in englishKeys where englishPlurals[key] != nil {
        problems.append(Problem(file: enPath, line: 0,
                                message: "\"\(key)\" has plural forms: it belongs in the .stringsdict only (run sync)"))
    }
    if allKeys != used { return problems }   // sync first; the languages are compared with en's keys
    let pluralKeys = Set(englishPlurals.keys)
    for language in languages {
        let path = stringsPath(language, "Localizable")
        guard let file = readStrings(path) else {
            problems.append(Problem(file: path, line: 0, message: "missing"))
            continue
        }
        if !appleReads(path, file) { problems.append(Problem(file: path, line: 0, message: "macOS cannot read it")) }
        let values = Dictionary(file.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        for key in englishKeys where !pluralKeys.contains(key) {
            guard let value = values[key] else {
                problems.append(Problem(file: path, line: 0, message: "\"\(key)\" has no \(language) text"))
                continue
            }
            problems += textProblems(key, language, value, expected: specifiers(key), file: path)
        }
        for key in values.keys where !used.contains(key) || pluralKeys.contains(key) {
            problems.append(Problem(file: path, line: 0, message: "\"\(key)\" should not be here (run sync)"))
        }
        let plurals = readPlurals(language)
        for key in pluralKeys {
            guard let forms = plurals[key] else {
                problems.append(Problem(file: pluralPath(language), line: 0, message: "\"\(key)\" has no plural forms"))
                continue
            }
            let expected = specifiers(englishPlurals[key]?["other"] ?? key)
            for category in pluralCategories[language] ?? ["one", "other"] where forms[category] == nil {
                problems.append(Problem(file: pluralPath(language), line: 0, message: "\"\(key)\" lacks the form \(category)"))
            }
            for (category, form) in forms {
                let found = specifiers(form)
                if category == "other" ? found != expected : !isSubsequence(found, of: expected) {
                    problems.append(Problem(file: pluralPath(language), line: 0,
                                            message: "\"\(key)\" \(category): format \(found) ≠ \(expected)"))
                }
            }
        }
        for key in plurals.keys where !pluralKeys.contains(key) {
            problems.append(Problem(file: pluralPath(language), line: 0, message: "\"\(key)\" is not a plural key in en"))
        }
    }
    // Exactly the folders of the languages, and nothing that the app would load besides them.
    let folders = ((try? FileManager.default.contentsOfDirectory(atPath: localizationPath)) ?? [])
        .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }
    if Set(folders) != Set(["en"] + languages) {
        problems.append(Problem(file: localizationPath, line: 0,
                                message: "language folders \(folders.sorted()) ≠ en + Localization.languages"))
    }
    return problems
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
    for language in ["en"] + languages {
        let path = stringsPath(language, "InfoPlist")
        guard let file = readStrings(path) else {
            problems.append(Problem(file: path, line: 0, message: "missing"))
            continue
        }
        if !appleReads(path, file) { problems.append(Problem(file: path, line: 0, message: "macOS cannot read it")) }
        let values = Dictionary(file.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        for (key, english) in shown {
            guard let value = values[key], !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                problems.append(Problem(file: path, line: 0, message: "\"\(key)\" has no text"))
                continue
            }
            if language == "en" && value != english {
                problems.append(Problem(file: path, line: 0, message: "\"\(key)\" differs from build-app.sh's Info.plist"))
            }
        }
        for key in values.keys where shown[key] == nil {
            problems.append(Problem(file: path, line: 0, message: "\"\(key)\" is not in the Info.plist"))
        }
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

/// The texts `export` numbers and `import` reads back: for Localizable every key the code uses in en's order (plural
/// keys included, though en.lproj keeps them in the .stringsdict only), for InfoPlist en's entries.
func exportedTexts() -> [Entry] {
    guard table == "Localizable" else { return readStrings(stringsPath("en", table))?.entries ?? [] }
    return englishEntries(scanSources().uses, existing: readStrings(stringsPath("en", "Localizable")),
                          plurals: Set(readPlurals("en").keys))
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
    var problems = scanned.problems + languageFileProblems(uses: scanned.uses)
    problems += infoPlistProblems() + languageListProblems()
    printProblems(problems)
    let keys = Set(scanned.uses.map(\.key)).count
    print("\(keys) keys in \(covered.count) covered files, \(languages.count) languages; \(problems.count) problems; "
          + "\(scanned.uncovered.count) phrase-like strings in files not covered yet")
    exit(problems.isEmpty ? 0 : 1)

case "sync":
    let scanned = scanSources()
    let plurals = readPlurals("en")
    let english = englishEntries(scanned.uses, existing: readStrings(stringsPath("en", "Localizable")),
                                 plurals: Set(plurals.keys))
    // A plural key is only in the .stringsdict, where its forms are.
    writeStrings(StringsFile(status: nil, entries: english.filter { plurals[$0.key] == nil }), language: "en",
                 table: "Localizable")
    let used = Set(english.map(\.key))
    writePlurals(plurals.filter { used.contains($0.key) }, language: "en")
    let enInfo = readStrings(stringsPath("en", "InfoPlist"))?.entries ?? []
    for language in languages {
        let file = readStrings(stringsPath(language, "Localizable"))
        writeStrings(reordered(file, like: english, skipping: Set(plurals.keys)), language: language, table: "Localizable")
        writePlurals(readPlurals(language).filter { used.contains($0.key) }, language: language)
        let info = readStrings(stringsPath(language, "InfoPlist"))
        writeStrings(reordered(info, like: enInfo), language: language, table: "InfoPlist")
    }
    print("\(lproj("en")): \(english.count) keys, \(plurals.count) with plural forms; \(languages.count) languages re-ordered")

case "report":
    let scanned = scanSources()
    let english = readStrings(stringsPath("en", "Localizable"))?.entries ?? []
    let pluralKeys = Set(readPlurals("en").keys)
    for language in languages {
        let file = readStrings(stringsPath(language, "Localizable"))
        let present = Set((file?.entries ?? []).map(\.key)).union(readPlurals(language).keys)
        let missing = english.filter { !present.contains($0.key) }.count
        print("\(language.padding(toLength: 8, withPad: " ", startingAt: 0)) \(english.count - missing) of \(english.count) "
              + "(\(pluralKeys.count) plural)" + (file?.status.map { "  \($0)" } ?? ""))
    }
    var perFile: [String: Int] = [:]
    for p in scanned.uncovered { perFile[p.file, default: 0] += 1 }
    print("\nPhrase-like strings outside L in files not covered yet:")
    for (file, count) in perFile.sorted(by: { $0.value > $1.value }) { print("  \(count)\t\(file)") }

case "export":
    guard let directory = commandArguments.first else { fail(usage: "export needs a directory") }
    let english = exportedTexts()
    let pluralKeys = table == "Localizable" ? Set(readPlurals("en").keys) : []
    var lines: [String] = []
    for (n, e) in english.enumerated() {
        lines.append("\(n + 1)\t\(escapeTSV(e.value))\t\(pluralKeys.contains(e.key) ? "plural" : "")\t\(escapeTSV(e.comment))")
    }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try! (lines.joined(separator: "\n") + "\n").write(toFile: directory + "/source.tsv", atomically: true, encoding: .utf8)
    print("wrote \(directory)/source.tsv (\(english.count) \(table) texts)")

case "import":
    guard commandArguments.count >= 2 else { fail(usage: "import needs a directory and languages") }
    let directory = commandArguments[0]
    guard let source = try? String(contentsOfFile: directory + "/source.tsv", encoding: .utf8) else {
        fail(usage: "cannot read \(directory)/source.tsv")
    }
    let english = exportedTexts()
    // The numbers count en's entries; source.tsv's English must still match (nothing changed since the export).
    for row in source.split(separator: "\n") {
        let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 2, let n = Int(fields[0]) else { continue }
        guard n >= 1, n <= english.count, unescapeTSV(String(fields[1])) == english[n - 1].value else {
            fail(usage: "\(directory)/source.tsv no longer matches en.lproj (line \(n)): export again")
        }
    }
    let pluralKeys = table == "Localizable" ? Set(readPlurals("en").keys) : []
    let categoryPattern = try! NSRegularExpression(pattern: #"\{(zero|one|two|few|many|other)\}"#)
    var failed = false
    for language in commandArguments.dropFirst() {
        guard let text = try? String(contentsOfFile: directory + "/\(language).tsv", encoding: .utf8) else {
            fail(usage: "cannot read \(directory)/\(language).tsv")
        }
        var file = readStrings(stringsPath(language, table)) ?? StringsFile(status: nil, entries: [])
        var values = Dictionary(file.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        var plurals = table == "Localizable" ? readPlurals(language) : [:]
        var imported = 0
        for row in text.split(separator: "\n") {
            let fields = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let n = Int(fields[0].trimmingCharacters(in: .whitespaces)),
                  n >= 1, n <= english.count else {
                print("\(language).tsv: skipped line \(row.prefix(40))")
                failed = true
                continue
            }
            let key = english[n - 1].key
            let value = unescapeTSV(String(fields[1]))
            if pluralKeys.contains(key) {
                let ns = value as NSString
                let marks = categoryPattern.matches(in: value, range: NSRange(location: 0, length: ns.length))
                guard !marks.isEmpty else {
                    print("\(language).tsv: line \(n) is a plural key; write {one}… {other}…")
                    failed = true
                    continue
                }
                var forms: [String: String] = [:]
                for (index, mark) in marks.enumerated() {
                    let start = mark.range.location + mark.range.length
                    let end = index + 1 < marks.count ? marks[index + 1].range.location : ns.length
                    forms[ns.substring(with: mark.range(at: 1))] = ns.substring(with: NSRange(location: start, length: end - start))
                        .trimmingCharacters(in: .whitespaces)
                }
                plurals[key] = forms
            } else {
                values[key] = value
            }
            imported += 1
        }
        file.entries = english.compactMap { e in
            values[e.key].map { Entry(key: e.key, value: $0, comment: e.comment, section: e.section) }
        }
        writeStrings(file, language: language, table: table)
        if table == "Localizable" { writePlurals(plurals, language: language) }
        print("\(language): \(imported) \(table) texts imported")
    }
    exit(failed ? 1 : 0)

default:
    fail(usage: "unknown command \(command) (check, sync, report, export, import)")
}
