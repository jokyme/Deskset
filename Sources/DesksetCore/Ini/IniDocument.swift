import Foundation

/// One `Key=Value` line. `key` keeps its original spelling; every lookup is case-insensitive.
public struct IniEntry: Equatable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// A `[Section]` with its entries in file order. Section and key names are case-insensitive.
public struct IniSection: Equatable {
    public var name: String
    public var entries: [IniEntry]

    public init(name: String, entries: [IniEntry] = []) {
        self.name = name
        self.entries = entries
    }

    public var keys: [String] { entries.map(\.key) }

    /// Case-insensitive lookup; nil when the key is absent.
    public func value(forKey key: String) -> String? {
        entries.first { IniSyntax.namesEqual($0.key, key) }?.value
    }

    public subscript(key: String) -> String? { value(forKey: key) }

    /// Replaces the value of an existing key (keeping its position) or appends a new entry.
    public mutating func setValue(_ value: String, forKey key: String) {
        if let i = entries.firstIndex(where: { IniSyntax.namesEqual($0.key, key) }) {
            entries[i].value = value
        } else {
            entries.append(IniEntry(key: key, value: value))
        }
    }

    public mutating func removeValue(forKey key: String) {
        entries.removeAll { IniSyntax.namesEqual($0.key, key) }
    }
}

/// A parsed INI file: sections in file order, section names unique (case-insensitive).
public struct IniDocument: Equatable {
    public var sections: [IniSection] {
        didSet { names = SectionNameIndex() }
    }
    /// Section name → index, built on the first lookup after a change (the editor names every section of a big
    /// skin many times over: a linear scan per lookup made that quadratic).
    private var names = SectionNameIndex()

    public init(sections: [IniSection] = []) {
        self.sections = sections
    }

    public func indexOfSection(named name: String) -> Int? {
        names.index(of: name, in: sections)
    }

    public static func == (a: IniDocument, b: IniDocument) -> Bool { a.sections == b.sections }

    public func section(named name: String) -> IniSection? {
        indexOfSection(named: name).map { sections[$0] }
    }

    /// Parses the text of ONE INI file (no `@Include` processing — see `SkinFileLoader`), following the manual:
    /// - Only `\r\n`, `\r` and `\n` end a line. Lines whose first non-blank character is `;` are comments; there are
    ///   no inline comments (`Text=a ; b` has the value `a ; b`).
    /// - Section names, keys and values are trimmed of spaces/tabs; one pair of identical quotes (`"` or `'`)
    ///   wrapping the whole value is removed ("Rainmeter will ignore quotes around option values").
    /// - A section that appears a second time in the same file is ignored entirely (manual: "If both are in the
    ///   actual .ini file, the second one is entirely ignored"); within a section the first definition of a key wins.
    /// - Lines before the first section header, lines without `=`, lines with an empty key and the keys under an
    ///   empty header `[]` are ignored. `@Include` keys are ordinary entries here.
    public static func parse(_ text: String) -> IniDocument {
        let file = IniSyntax.parseFile(text)
        return IniDocument(sections: file.sections.map { IniSection(name: $0.name, entries: $0.entries) })
    }

    static func unquote(_ value: String) -> String {
        String(IniSyntax.unquote(Substring(value)))
    }
}

/// The lookup table behind `IniDocument.indexOfSection(named:)`: lowercased name → the first section with that name.
/// A class so a lookup can fill it without mutating the document; a changed document gets a new, empty one.
private final class SectionNameIndex {
    private let lock = NSLock()
    private var table: [String: Int]?

    func index(of name: String, in sections: [IniSection]) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if table == nil {
            var built: [String: Int] = [:]
            built.reserveCapacity(sections.count)
            for (i, s) in sections.enumerated() where built[s.name.lowercased()] == nil { built[s.name.lowercased()] = i }
            table = built
        }
        return table?[name.lowercased()]
    }
}
