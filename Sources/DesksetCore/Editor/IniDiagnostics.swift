import Foundation

/// A problem in an INI widget's files, as the Studio's code pane shows it: under the line that causes it, with the
/// words the Studio uses (the App turns `kind` into a sentence), the parts it touches and — when the change is certain —
/// a fix.
///
/// Two kinds, as the widget sees them:
/// - **warning** (amber): the widget still draws, with a default where the file says something the engine does not
///   take — a key that is not an option of the section's type (a misspelling, with a did-you-mean), a color that does
///   not read as one.
/// - **problem** (red): a part cannot draw or cannot do what it says — a number option whose formula cannot be worked
///   out, `MeasureName` / `MeterStyle` / `@Include` / an image that points at nothing, a bang that does not exist.
public struct IniDiagnostic: Equatable {
    public enum Severity: Int, Equatable, Comparable {
        case warning
        case problem

        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// Why a formula cannot be worked out.
    public enum FormulaReason: Equatable {
        /// An operator with nothing after it: `(#W# *)`.
        case missingNumber(after: String)
        /// A `(` that is never closed.
        case missingParenthesis
        case unknownFunction(String)
        case empty
        /// Anything else, in the formula engine's words.
        case other(String)
    }

    public enum Kind: Equatable {
        /// `key` is not an option of `sectionType` (a meter or measure type as the manual spells it); `suggestion` is
        /// the option it most likely means.
        case unknownKey(key: String, sectionType: String, suggestion: String)
        /// A color option whose value is not a color: the default color applies.
        case badColor(key: String, value: String)
        case badFormula(key: String, value: String, reason: FormulaReason)
        case missingMeasure(name: String)
        case missingStyle(name: String)
        case missingInclude(path: String)
        case missingImage(path: String)
        /// A bang the engine does not know (`!SetOpton`), and the one it most likely means (`!SetOption`).
        case unknownBang(name: String, suggestion: String?)
    }

    /// A change of the line that fixes the problem: `length` characters at `column` become `text`.
    public struct Fix: Equatable {
        public var column: Int
        public var length: Int
        public var text: String

        public init(column: Int, length: Int, text: String) {
            self.column = column
            self.length = length
            self.text = text
        }
    }

    /// The file and 1-based line the problem is written on.
    public var file: URL
    public var line: Int
    /// What to mark in the line: UTF-16 offset and length.
    public var column: Int
    public var length: Int
    /// The section the line is in (a meter, a measure, a MeterStyle, `[Rainmeter]`…).
    public var section: String
    public var kind: Kind
    /// The meters the line reaches, in the skin's order: those that cannot draw (a problem), or that draw with a default
    /// (a warning).
    public var meters: [String]
    /// What applies meanwhile: the default of the option meant (a misspelled key) or of the option itself (a color).
    public var defaultValue: String?
    public var fix: Fix?

    public var severity: Severity {
        switch kind {
        case .unknownKey, .badColor: return .warning
        default: return .problem
        }
    }

    public init(file: URL, line: Int, column: Int, length: Int, section: String, kind: Kind, meters: [String] = [],
                defaultValue: String? = nil, fix: Fix? = nil) {
        self.file = file
        self.line = line
        self.column = column
        self.length = length
        self.section = section
        self.kind = kind
        self.meters = meters
        self.defaultValue = defaultValue
        self.fix = fix
    }
}

/// The INI diagnostics of the Studio's code pane (compatibility mode): what `IniDiagnostic` lists, found in the
/// widget's files as the text in memory holds them, placed on lines by the skin's source map (`IniSourceMap`).
///
/// The checks read the files as the engine does (the merged document, `@Include`s, MeterStyles — the section's own key
/// first, later styles over earlier ones —, variables) and stay on the safe side: a value that still depends on what
/// the widget does at run time (`[Measure]`, a variable nobody defines) is not judged, and a key is called unknown only
/// when it is close to one the type has (a misspelling), since Rainmeter ignores keys it does not use.
public enum IniDiagnostics {
    /// How long typing pauses before the code pane checks.
    public static let checkDelay: TimeInterval = 0.3

    /// The problems of `skin`'s files: as the skin loaded them, or — `sources` given — as `sources` holds them now
    /// (typed code not committed yet), with the skin's built-in variables and paths. Sorted by file (the main file,
    /// then the included files in load order) and line.
    public static func check(_ skin: Skin, sources: SourceProvider? = nil) -> [IniDiagnostic] {
        let builtins = skin.builtInVariables()
        let loaded: LoadedIniFile
        if let sources {
            guard let fresh = try? SkinFileLoader.load(url: skin.fileURL, sources: sources, expandVariables: { raw, soFar in
                VariableResolver(variableLookup: { soFar[$0.lowercased()] ?? builtins[$0.lowercased()] }).resolve(raw)
            }) else { return [] }
            loaded = fresh
        } else {
            loaded = LoadedIniFile(document: skin.document, includedFiles: skin.includedFiles,
                                   warnings: skin.loadWarnings, sources: skin.sources)
        }
        var checker = Checker(skin: skin, loaded: loaded, builtins: builtins) { url in
            sources?.sourceText(for: url) ?? skin.sourceText(of: url)
        }
        return checker.run()
    }

    /// Whether any of `diagnostics` stops a part from drawing (the desktop keeps the last working version then).
    public static func hasProblems(_ diagnostics: [IniDiagnostic]) -> Bool {
        diagnostics.contains { $0.severity == .problem }
    }

    // MARK: Did you mean

    /// The candidate closest to `word` (case-insensitive optimal string alignment distance), when it is close enough
    /// to be a misspelling: one edit for short words, two from seven letters on. nil for an exact match.
    public static func closest(to word: String, in candidates: [String]) -> String? {
        let w = word.lowercased()
        let limit = w.count >= 7 ? 2 : 1
        var best: (String, Int)?
        for c in candidates {
            let d = distance(w, c.lowercased(), limit: limit)
            guard d > 0, d <= limit else { continue }
            if best == nil || d < best!.1 { best = (c, d) }
        }
        return best?.0
    }

    /// Optimal string alignment (Damerau–Levenshtein without repeated edits of one substring), giving up above `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var previous2 = [Int](repeating: 0, count: y.count + 1)
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                var v = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { v = min(v, previous2[j - 2] + 1) }
                current[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return limit + 1 }
            previous2 = previous
            previous = current
        }
        return previous[y.count]
    }

    /// Why `formula` (variables already in) cannot be worked out, from the formula engine's error.
    static func reason(_ error: FormulaError, in formula: String) -> IniDiagnostic.FormulaReason {
        let message = error.message
        if message == "empty formula" { return .empty }
        if message.hasPrefix("missing ')'") { return .missingParenthesis }
        if message.hasPrefix("unknown function '"), let end = message.dropFirst(18).firstIndex(of: "'") {
            return .unknownFunction(String(message.dropFirst(18)[..<end]))
        }
        if message.hasPrefix("unexpected "), let at = message.range(of: " at position "),
           let offset = Int(message[at.upperBound...]) {
            // What comes before the unexpected token: an operator waiting for its number.
            let chars = Array(formula)
            var i = min(offset, chars.count) - 1
            while i >= 0, chars[i] == " " || chars[i] == "\t" { i -= 1 }
            if i >= 0, "+-*/%^&|<>=?:~".contains(chars[i]) {
                var op = String(chars[i])
                if i >= 1, ["**", "&&", "||", "<=", ">=", "<>"].contains(String(chars[i - 1]) + op) {
                    op = String(chars[i - 1]) + op
                }
                return .missingNumber(after: op)
            }
        }
        return .other(message)
    }
}

// MARK: - The checks

private struct Checker {
    let skin: Skin
    let loaded: LoadedIniFile
    let builtins: [String: String]
    let text: (URL) -> String?
    /// The skin's `[Variables]` as the merged document holds them (lowercased names).
    var variables: [String: String] = [:]
    /// Measure sections (lowercased name → section).
    var measures: [String: IniSection] = [:]
    var lines: [SourceFileID: (text: String, document: CodeDocument)] = [:]
    var texts: [SourceFileID: String?] = [:]
    /// Measure (lowercased) → the meters whose `MeasureName`s name it, in the skin's order.
    var shown: [String: [String]] = [:]
    var found: [IniDiagnostic] = []

    /// One option as a meter takes it: its own, else from the last MeterStyle that has it.
    struct Taken {
        var key: String
        var value: String
        /// The section the option is written in (the meter, or the style).
        var owner: String
    }

    init(skin: Skin, loaded: LoadedIniFile, builtins: [String: String], text: @escaping (URL) -> String?) {
        self.skin = skin
        self.loaded = loaded
        self.builtins = builtins
        self.text = text
        for e in loaded.document.section(named: "Variables")?.entries ?? [] where variables[e.key.lowercased()] == nil {
            variables[e.key.lowercased()] = e.value
        }
        for s in loaded.document.sections where s.value(forKey: "Measure") != nil {
            if measures[s.name.lowercased()] == nil { measures[s.name.lowercased()] = s }
        }
    }

    var document: IniDocument { loaded.document }

    mutating func run() -> [IniDiagnostic] {
        // "owner|key" → the meters that take the option written there, with their types.
        var stylePlaces: [String: [(meter: String, type: String, taken: Taken)]] = [:]
        for section in document.sections {
            guard let type = section.value(forKey: "Meter").map({ resolve($0, in: section.name) }) else { continue }
            let t = type.trimmingCharacters(in: .whitespaces).lowercased()
            let options = taken(by: section)
            for o in options {
                if Self.isNumbered(o.key, "measurename") {
                    let name = resolve(o.value, in: section.name).trimmingCharacters(in: .whitespaces).lowercased()
                    if !(shown[name]?.contains(section.name) ?? false) { shown[name, default: []].append(section.name) }
                }
                stylePlaces["\(o.owner.lowercased())|\(o.key.lowercased())", default: []]
                    .append((section.name, t, o))
            }
            checkReferences(of: section, type: t, options: options)
        }
        checkMeterOptions(stylePlaces)
        checkMeasures()
        checkBangs(stylePlaces)
        checkIncludes()
        return sorted()
    }

    // MARK: Options a meter takes

    func taken(by meter: IniSection) -> [Taken] {
        var result: [Taken] = []
        var seen: Set<String> = []
        for e in meter.entries where seen.insert(e.key.lowercased()).inserted {
            result.append(Taken(key: e.key, value: e.value, owner: meter.name))
        }
        for name in styleNames(of: meter).reversed() {
            guard let s = document.section(named: name) else { continue }
            for e in s.entries where seen.insert(e.key.lowercased()).inserted {
                result.append(Taken(key: e.key, value: e.value, owner: s.name))
            }
        }
        return result
    }

    func styleNames(of meter: IniSection) -> [String] {
        guard let raw = meter.value(forKey: "MeterStyle") else { return [] }
        return resolve(raw, in: meter.name).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Keys, colors and formulas of meters

    mutating func checkMeterOptions(_ places: [String: [(meter: String, type: String, taken: Taken)]]) {
        for (_, users) in places.sorted(by: { $0.key < $1.key }) {
            guard let first = users.first else { continue }
            let o = first.taken
            let key = o.key.lowercased()
            if ["meter", "meterstyle"].contains(key) { continue }
            let meters = users.map(\.meter)
            let types = users.map(\.type)
            // A key none of the types using it takes, close to one they all could mean.
            let indexes = types.map { SchemaIndex.meter($0) }
            // A Shape meter reads options of any name its shapes point at (`Path MyPath`, `Fill LinearGradient G`).
            if !indexes.contains(where: \.isEmpty), !types.contains("shape"), indexes.allSatisfy({ !$0.takes(o.key) }) {
                if let suggestion = indexes[0].closest(to: o.key),
                   indexes.allSatisfy({ $0.property(suggestion) != nil }) {
                    let property = indexes[0].property(suggestion)
                    add(owner: o.owner, key: o.key, part: .key, kind: .unknownKey(key: o.key,
                        sectionType: Self.typeName(types[0]), suggestion: suggestion), meters: meters,
                        defaultValue: property?.defaultValue, fixText: suggestion)
                }
                continue
            }
            // Resolved as the first meter taking it resolves it (#CURRENTSECTION# is the meter's).
            let property = indexes.first?.property(o.key)
            let isNumber = ["x", "y", "w", "h"].contains(key) || (property?.kind.isNumeric ?? false)
            // Only colors and numbers are judged: nothing else is resolved (the check runs after every step).
            guard property?.kind == .color || (isNumber && o.value.contains("(")) else { continue }
            let value = resolve(o.value, in: first.meter)
            if property?.kind == .color {
                let v = value.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty, !v.contains("["), !v.contains("#"), OptionValue.color(v) == nil {
                    add(owner: o.owner, key: o.key, part: .value, kind: .badColor(key: o.key, value: o.value),
                        meters: meters, defaultValue: property?.defaultValue)
                }
            }
            if isNumber, let reason = Self.formulaProblem(value, position: key == "x" || key == "y") {
                add(owner: o.owner, key: o.key, part: .value,
                    kind: .badFormula(key: o.key, value: o.value, reason: reason), meters: meters)
            }
        }
    }


    /// A meter type as the manual spells it (`string` → `String`).
    static func typeName(_ type: String) -> String {
        EditorSchema.meterTypes.first { $0.lowercased() == type } ?? type
    }

    /// Why a number option's value (variables in) cannot be worked out; nil when it can, or when it is not a formula
    /// (a plain number, or text the engine reads its number from).
    static func formulaProblem(_ value: String, position: Bool) -> IniDiagnostic.FormulaReason? {
        guard value.contains("(") else { return nil }
        var v = withoutSectionVariables(value).trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("(") else { return nil }
        if position, let last = v.last, last == "r" || last == "R" { v.removeLast() }
        // A variable nobody defines (a built-in the Studio does not know) is not judged.
        if v.contains("#") { v = v.replacingOccurrences(of: #"#[^#\s]+#"#, with: "1", options: .regularExpression) }
        guard Formula.number(v) == nil else { return nil }
        do {
            _ = try CompiledFormula(v)
            return nil
        } catch let error as FormulaError {
            return IniDiagnostics.reason(error, in: v)
        } catch {
            return .other("\(error)")
        }
    }

    /// `[Measure]`, `[Meter:W]`, `[&Script:F()]` and the like: what the widget knows only while it runs, as 1.
    static func withoutSectionVariables(_ value: String) -> String {
        guard value.contains("[") else { return value }
        var v = value
        for _ in 0..<8 {
            let next = v.replacingOccurrences(of: #"\[[^\[\]!]*\]"#, with: "1", options: .regularExpression)
            if next == v { break }
            v = next
        }
        return v
    }

    // MARK: MeasureName, MeterStyle, images

    mutating func checkReferences(of meter: IniSection, type: String, options: [Taken]) {
        for o in options {
            let key = o.key.lowercased()
            let isMeasure = Self.isNumbered(key, "measurename"), isImage = Self.imageKeys(type).contains(key)
            guard isMeasure || isImage || key == "meterstyle" else { continue }
            let value = resolve(o.value, in: meter.name).trimmingCharacters(in: .whitespaces)
            if isMeasure {
                if !value.isEmpty, !value.contains("["), !value.contains("#"), measures[value.lowercased()] == nil {
                    add(owner: o.owner, key: o.key, part: .value, kind: .missingMeasure(name: value), meters: [meter.name])
                }
            }
            if key == "meterstyle" {
                for name in styleNames(of: meter) where !name.contains("#") && !name.contains("[")
                    && document.section(named: name) == nil {
                    add(owner: o.owner, key: o.key, part: .word(name), kind: .missingStyle(name: name),
                        meters: [meter.name])
                }
            }
            // `%1`: the name comes from the meter's measure while it runs.
            if isImage, !value.isEmpty, !value.contains("["), !value.contains("#"), !value.contains("%"),
               !value.lowercased().hasPrefix("sf:") {
                let imagePath = options.first { $0.key.lowercased() == "imagepath" }
                    .map { resolve($0.value, in: meter.name) } ?? ""
                let path = skin.imageFilePath(value, imagePath: imagePath)
                if !FileManager.default.fileExists(atPath: path) {
                    add(owner: o.owner, key: o.key, part: .value,
                        kind: .missingImage(path: o.value.trimmingCharacters(in: .whitespaces)), meters: [meter.name])
                }
            }
        }
    }

    /// `key` is `base` or a numbered copy of it (`MeasureName`, `MeasureName2`), letter case ignored.
    static func isNumbered(_ key: String, _ base: String) -> Bool {
        let lower = key.lowercased()
        guard lower.hasPrefix(base) else { return false }
        return lower.dropFirst(base.count).allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// An action option: its name ends with "Action" (and maybe a number: `IfTrueAction2`, `ContextAction3`).
    static func isAction(_ key: String) -> Bool {
        let lower = key.lowercased()
        let digits = lower.reversed().prefix { $0.isASCII && $0.isNumber }.count
        return lower.dropLast(digits).hasSuffix("action")
    }

    /// The options of a meter type that name an image file.
    static func imageKeys(_ type: String) -> Set<String> {
        switch type {
        case "image": return ["imagename", "maskimagename"]
        case "rotator": return ["imagename"]
        case "button": return ["buttonimage"]
        case "bar": return ["barimage"]
        case "bitmap": return ["bitmapimage"]
        default: return []
        }
    }

    // MARK: Measures

    mutating func checkMeasures() {
        for section in document.sections {
            guard let raw = section.value(forKey: "Measure") else { continue }
            let type = resolve(raw, in: section.name).trimmingCharacters(in: .whitespaces)
            let lower = type.lowercased()
            // Add-ons read keys of their own, and a script reads what it likes.
            guard lower != "plugin", lower != "script", EditorSchema.measureType(type: type) != nil else { continue }
            let index = SchemaIndex.measure(type)
            let users = metersShowing(section.name)
            var seen: Set<String> = []
            for e in section.entries where seen.insert(e.key.lowercased()).inserted {
                let key = e.key.lowercased()
                if key == "measure" { continue }
                if !index.takes(e.key) {
                    if let suggestion = index.closest(to: e.key) {
                        add(owner: section.name, key: e.key, part: .key,
                            kind: .unknownKey(key: e.key, sectionType: EditorSchema.measureType(type: type)?.name ?? type,
                                              suggestion: suggestion),
                            meters: users, defaultValue: index.property(suggestion)?.defaultValue,
                            fixText: suggestion)
                    }
                    continue
                }
                if lower == "calc", key == "formula" {
                    var v = Self.withoutSectionVariables(resolve(e.value, in: section.name))
                    if v.contains("#") {
                        v = v.replacingOccurrences(of: #"#[^#\s]+#"#, with: "1", options: .regularExpression)
                    }
                    guard !v.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    do {
                        _ = try CompiledFormula(v)
                    } catch let error as FormulaError {
                        add(owner: section.name, key: e.key, part: .value,
                            kind: .badFormula(key: e.key, value: e.value, reason: IniDiagnostics.reason(error, in: v)),
                            meters: users)
                    } catch {}
                }
            }
        }
    }

    /// The meters whose `MeasureName`s name `measure`.
    func metersShowing(_ measure: String) -> [String] {
        shown[measure.lowercased()] ?? []
    }

    // MARK: Bangs

    mutating func checkBangs(_ places: [String: [(meter: String, type: String, taken: Taken)]]) {
        let names = BangCatalog.all.map(\.displayName)
        for section in document.sections {
            var seen: Set<String> = []
            for e in section.entries where seen.insert(e.key.lowercased()).inserted {
                guard Self.isAction(e.key) else {
                    continue
                }
                for parsed in ActionParser.parseDetailed(e.value) {
                    // `!Mac…`: Deskset's own bangs, some of them still to come.
                    guard case .bang(let bang) = parsed.action, !BangCatalog.isKnown(bang.name),
                          !bang.name.hasPrefix("mac"), let written = Self.writtenBang(bang.name, in: e.value) else {
                        continue
                    }
                    let users = places["\(section.name.lowercased())|\(e.key.lowercased())"]?.map(\.meter)
                        ?? (section.value(forKey: "Meter") != nil ? [section.name] : [])
                    let suggestion = IniDiagnostics.closest(to: written, in: names)
                    add(owner: section.name, key: e.key, part: .word(written),
                        kind: .unknownBang(name: written, suggestion: suggestion), meters: users, fixText: suggestion)
                }
            }
        }
    }

    /// The bang as the file spells it (`!SetOpton`), found by its canonical name.
    static func writtenBang(_ canonical: String, in value: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"![A-Za-z0-9_]+"#) else { return nil }
        let ns = value as NSString
        for m in re.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range)
            if BangCatalog.canonicalName(word) == canonical { return word }
        }
        return nil
    }

    // MARK: @Include

    mutating func checkIncludes() {
        let main = skin.fileURL
        let files = [main] + loaded.includedFiles
        let variables = self.variables, builtins = self.builtins
        for file in files {
            // Most files include nothing: they are not read line by line.
            guard let raw = source(of: file), Self.mentionsInclude(raw),
                  let doc = document(of: file) else { continue }
            var section: String?
            for line in 1...max(doc.document.lineCount, 1) {
                let range = doc.document.range(ofLine: line)
                let text = (doc.text as NSString).substring(with: range)
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                    section = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                    continue
                }
                guard let section, let eq = trimmed.firstIndex(of: "="),
                      trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("@include") else {
                    continue
                }
                let raw = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                let written = Self.unquoted(raw)
                guard !written.isEmpty else { continue }
                let path = VariableResolver(variableLookup: { variables[$0.lowercased()] ?? builtins[$0.lowercased()] })
                    .resolve(written).replacingOccurrences(of: "\\", with: "/")
                // Only files of the widget's own folders are judged: an include of a settings file that is written
                // later (the user's choices) may be missing on purpose.
                guard !path.contains("#"), Self.isInside(path, skin.rootConfigDirectory, main: main),
                      !Self.includeExists(path, main: main, including: file, loaded: loaded.includedFiles) else {
                    continue
                }
                let column = (text as NSString).range(of: raw).location
                found.append(IniDiagnostic(file: file, line: line, column: column == NSNotFound ? 0 : column,
                                           length: (raw as NSString).length, section: section,
                                           kind: .missingInclude(path: written)))
            }
        }
    }

    /// Whether an include path (absolute, or relative to the skin's folder) is inside `folder`.
    static func isInside(_ path: String, _ folder: URL, main: URL) -> Bool {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : main.deletingLastPathComponent().appendingPathComponent(path)
        let root = folder.standardizedFileURL.path.lowercased()
        return url.standardizedFileURL.path.lowercased().hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Whether `text` has "@include" anywhere (letter case ignored): a quick scan of its bytes.
    static func mentionsInclude(_ text: String) -> Bool {
        let word: [UInt8] = Array("include".utf8)
        var bytes = text.utf8.makeIterator()
        var matched = -1
        while let b = bytes.next() {
            if b == 0x40 { // @
                matched = 0
                continue
            }
            guard matched >= 0 else { continue }
            let lower = b >= 0x41 && b <= 0x5A ? b + 0x20 : b
            if lower == word[matched] {
                matched += 1
                if matched == word.count { return true }
            } else {
                matched = -1
            }
        }
        return false
    }

    static func unquoted(_ value: String) -> String {
        var v = value
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
        return v.trimmingCharacters(in: .whitespaces)
    }

    /// Whether an include path reaches a file, as the loader looks for it: from the skin's folder, then the including
    /// file's, letter case ignored.
    static func includeExists(_ path: String, main: URL, including: URL, loaded: [URL]) -> Bool {
        if path.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil { return true } // a Windows drive: not judged
        var candidates: [URL] = []
        if path.hasPrefix("/") {
            candidates = [URL(fileURLWithPath: path)]
        } else {
            candidates = [main.deletingLastPathComponent().appendingPathComponent(path),
                          including.deletingLastPathComponent().appendingPathComponent(path)]
        }
        let ids = Set(loaded.map { SourceFileID($0) })
        for url in candidates {
            if ids.contains(SourceFileID(url)) || FileManager.default.fileExists(atPath: url.standardizedFileURL.path) {
                return true
            }
            // Letter case ignored, as on Windows.
            let folder = url.standardizedFileURL.deletingLastPathComponent()
            let name = url.lastPathComponent.lowercased()
            if let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
               items.contains(where: { $0.lowercased() == name }) {
                return true
            }
        }
        return false
    }

    // MARK: Placing

    enum Part {
        case key
        case value
        /// A word in the value (a style's name, a bang).
        case word(String)
    }

    /// Adds a diagnostic on the line where `owner`'s `key` is written (merging the meters of one already there).
    mutating func add(owner: String, key: String, part: Part, kind: IniDiagnostic.Kind, meters: [String],
                      defaultValue: String? = nil, fixText: String? = nil) {
        guard let location = loaded.sources.location(section: owner, key: key),
              let doc = document(of: location.file), location.line >= 1, location.line <= doc.document.lineCount else {
            return
        }
        let lineRange = doc.document.range(ofLine: location.line)
        let line = (doc.text as NSString).substring(with: lineRange) as NSString
        let eq = line.range(of: "=").location
        let keyStart = line.range(of: key, options: .caseInsensitive).location
        var column = 0, length = line.length
        switch part {
        case .key:
            if keyStart != NSNotFound {
                column = keyStart
                length = (key as NSString).length
            }
        case .value:
            if eq != NSNotFound {
                let rest = line.substring(from: eq + 1) as NSString
                let lead = rest.length - (rest as String).drop { $0 == " " || $0 == "\t" }.utf16.count
                column = eq + 1 + lead
                length = ((rest as String).trimmingCharacters(in: .whitespaces) as NSString).length
            }
        case .word(let word):
            let from = eq == NSNotFound ? 0 : eq + 1
            let r = line.range(of: word, options: .caseInsensitive, range: NSRange(location: from, length: line.length - from))
            if r.location != NSNotFound {
                column = r.location
                length = r.length
            }
        }
        let fix = fixText.map { IniDiagnostic.Fix(column: column, length: length, text: $0) }
        if let i = found.firstIndex(where: { $0.file == location.file && $0.line == location.line && $0.kind == kind }) {
            for m in meters where !found[i].meters.contains(m) { found[i].meters.append(m) }
            return
        }
        found.append(IniDiagnostic(file: location.file, line: location.line, column: column, length: length,
                                   section: owner, kind: kind, meters: meters, defaultValue: defaultValue, fix: fix))
    }

    mutating func document(of file: URL) -> (text: String, document: CodeDocument)? {
        let id = SourceFileID(file)
        if let cached = lines[id] { return cached }
        guard let t = source(of: file) else { return nil }
        let entry = (t, CodeDocument(text: t))
        lines[id] = entry
        return entry
    }

    /// A file's text (read once).
    mutating func source(of file: URL) -> String? {
        let id = SourceFileID(file)
        if let cached = texts[id] { return cached }
        let t = text(file)
        texts[id] = t
        return t
    }

    /// `#Variables#` (the file's `[Variables]`, then the built-in ones; `#CURRENTSECTION#` is `section`).
    func resolve(_ raw: String, in section: String) -> String {
        guard raw.contains("#") || raw.contains("[") else { return raw }
        let variables = self.variables, builtins = self.builtins
        return VariableResolver(variableLookup: { name in
            let k = name.lowercased()
            if k == "currentsection" { return section }
            return variables[k] ?? builtins[k]
        }).resolve(raw)
    }

    /// The main file first, then the included files in load order; by line within a file; meters in skin order.
    func sorted() -> [IniDiagnostic] {
        let order = [SourceFileID(skin.fileURL)] + loaded.includedFiles.map { SourceFileID($0) }
        let meterOrder = document.sections.map { $0.name.lowercased() }
        return found.map { d -> IniDiagnostic in
            var d = d
            d.meters.sort { (meterOrder.firstIndex(of: $0.lowercased()) ?? .max) < (meterOrder.firstIndex(of: $1.lowercased()) ?? .max) }
            return d
        }.sorted { a, b in
            let fa = order.firstIndex(of: SourceFileID(a.file)) ?? .max, fb = order.firstIndex(of: SourceFileID(b.file)) ?? .max
            if fa != fb { return fa < fb }
            if a.line != b.line { return a.line < b.line }
            return a.column < b.column
        }
    }
}

/// The options a meter or measure type takes, from the schema, indexed once per type (the check asks for every option
/// of every part).
private final class SchemaIndex {
    struct Entry {
        var kind: EditorSchema.Kind
        var defaultValue: String
    }

    /// Lowercased key (legacy spellings too) → the option.
    let entries: [String: Entry]
    /// The options' names as the manual writes them (the did-you-mean's candidates).
    let candidates: [String]

    var isEmpty: Bool { entries.isEmpty }

    /// Options every meter and measure takes that the schema's cards leave to the inspector (place and size), and
    /// the inline settings of a String meter (their own editor, not the cards).
    static let generalKeys: Set<String> = ["x", "y", "w", "h", "meter", "meterstyle", "measure", "inlinesetting",
                                           "inlinepattern"]

    init(_ groups: [EditorSchema.Group]) {
        var entries: [String: Entry] = [:]
        var candidates: [String] = []
        for g in groups {
            for p in g.properties {
                let entry = Entry(kind: p.kind, defaultValue: p.defaultValue)
                if entries[p.key.lowercased()] == nil { entries[p.key.lowercased()] = entry }
                for legacy in p.legacyKeys where entries[legacy.lowercased()] == nil { entries[legacy.lowercased()] = entry }
                candidates.append(p.key)
            }
        }
        self.entries = entries
        self.candidates = candidates
    }

    /// The option `key` names: itself, or the first of a numbered family (`IfCondition2`, `Shape3`).
    func property(_ key: String) -> Entry? {
        let lower = key.trimmingCharacters(in: .whitespaces).lowercased()
        if let e = entries[lower] { return e }
        let digits = lower.reversed().prefix { $0.isASCII && $0.isNumber }.count
        guard digits > 0, digits < lower.count else { return nil }
        return entries[String(lower.dropLast(digits))]
    }

    /// Whether the type takes `key`: one of its options, a numbered copy of one (the engine reads any option that way
    /// once the first one is set), or place and size.
    func takes(_ key: String) -> Bool {
        let lower = key.lowercased()
        // Deskset's own options all start with Mac (some still to come).
        if lower.hasPrefix("mac") || Self.generalKeys.contains(lower) || property(key) != nil { return true }
        let digits = lower.reversed().prefix { $0.isASCII && $0.isNumber }.count
        return digits > 0 && Self.generalKeys.contains(String(lower.dropLast(digits)))
    }

    private var closestMemo: [String: String?] = [:]
    private let memoLock = NSLock()

    /// The option a misspelled key most likely means (worked out once per key and type).
    func closest(to key: String) -> String? {
        let lower = key.lowercased()
        memoLock.lock()
        if let known = closestMemo[lower] {
            memoLock.unlock()
            return known
        }
        memoLock.unlock()
        let found = IniDiagnostics.closest(to: key, in: candidates)
        memoLock.lock()
        closestMemo[lower] = found
        memoLock.unlock()
        return found
    }

    private static let lock = NSLock()
    private static var meters: [String: SchemaIndex] = [:]
    private static var measures: [String: SchemaIndex] = [:]

    static func meter(_ type: String) -> SchemaIndex {
        lock.lock()
        defer { lock.unlock() }
        if let cached = meters[type] { return cached }
        let index = SchemaIndex(EditorSchema.meterGroups(type))
        meters[type] = index
        return index
    }

    static func measure(_ type: String) -> SchemaIndex {
        lock.lock()
        defer { lock.unlock() }
        let key = type.lowercased()
        if let cached = measures[key] { return cached }
        let index = SchemaIndex(EditorSchema.measureGroups(type))
        measures[key] = index
        return index
    }
}
