import Foundation

/// The live raw options of one section, confined to its owner. Style/source queries are synchronous borrowed
/// callbacks: the stack never holds a Skin, section, context or resolver, and never resolves variables itself.
/// Keeping the index lazy preserves the original first-read and replacement behavior.
final class OptionStack {
    var own: IniSection {
        didSet { ownValues = OptionStack.index(own) }
    }
    private lazy var ownValues: [String: String] = OptionStack.index(own)
    var overrides: [String: String] = [:]
    var styles: [String] = []

    init(own: IniSection) { self.own = own }

    func rawOption(_ key: String, styleValues: (String) -> [String: String]?) -> String? {
        let lower = key.lowercased()
        if let found = rawOption(lowercased: lower, styleValues: styleValues) { return found }
        guard let alias = OptionStack.optionAliases[lower] else { return nil }
        return rawOption(lowercased: alias, styleValues: styleValues)
    }

    /// Misspelled or legacy option names that skins known to work in Rainmeter use in place of the documented name
    /// (lowercased documented name → lowercased alias). The documented spelling wins when both are set.
    /// - `ValueReminder` for `ValueRemainder` (Roundline, Rotator): the analog clocks of Enigma (21 uses in its
    ///   Sidebar / Taskbar / World clocks) and Elegant Watch set only this spelling, and their hands move on
    ///   Windows.
    static let optionAliases: [String: String] = [
        "valueremainder": "valuereminder",
    ]

    func fileOption(_ key: String, styleValues: (String) -> [String: String]?) -> String? {
        let lower = key.lowercased()
        var foundEmpty = false
        if let v = ownValues[lower] {
            if !v.isEmpty { return v }
            foundEmpty = true
        }
        for style in styles.reversed() {
            if let v = styleValues(style)?[lower] {
                if !v.isEmpty { return v }
                foundEmpty = true
            }
        }
        return foundEmpty ? "" : nil
    }

    func styleFileOption(_ key: String, styleValues: (String) -> [String: String]?) -> String? {
        let lower = key.lowercased()
        var foundEmpty = false
        for style in styles.reversed() {
            if let v = styleValues(style)?[lower] {
                if !v.isEmpty { return v }
                foundEmpty = true
            }
        }
        return foundEmpty ? "" : nil
    }

    func fileOrigin(_ key: String, sectionName: String,
                    styleValues: (String) -> [String: String]?, styleName: (String) -> String?,
                    location: (String, String) -> IniSourceLocation?) -> OptionOrigin? {
        let lower = key.lowercased()
        if ownValues[lower] != nil { return .own(location(sectionName, lower)) }
        for style in styles.reversed() where styleValues(style)?[lower] != nil {
            return .style(styleName(style) ?? style, location(style, lower))
        }
        return nil
    }

    func optionOrigin(_ key: String, sectionName: String,
                    styleValues: (String) -> [String: String]?, styleName: (String) -> String?,
                    location: (String, String) -> IniSourceLocation?) -> OptionOrigin? {
        let lower = key.lowercased()
        var ownRemoved = false
        if let v = overrides[lower] {
            if !v.isEmpty { return .setOption }
            ownRemoved = true
        }
        if !ownRemoved, own.entries.contains(where: { $0.key.lowercased() == lower }) {
            return .own(location(sectionName, lower))
        }
        for style in styles.reversed() where styleValues(style)?[lower] != nil {
            return .style(styleName(style) ?? style, location(style, lower))
        }
        return nil
    }

    private func rawOption(lowercased lower: String, styleValues: (String) -> [String: String]?) -> String? {
        var ownRemoved = false
        var foundEmpty = false
        if let v = overrides[lower] {
            if !v.isEmpty { return v }
            ownRemoved = true
        }
        if !ownRemoved, let v = ownValues[lower] {
            if !v.isEmpty { return v }
            foundEmpty = true
        }
        for style in styles.reversed() {
            if let v = styleValues(style)?[lower] {
                if !v.isEmpty { return v }
                foundEmpty = true
            }
        }
        return foundEmpty ? "" : nil
    }

    /// Entries keyed by lowercased name; the first definition of a key wins.
    static func index(_ section: IniSection) -> [String: String] {
        var values: [String: String] = [:]
        values.reserveCapacity(section.entries.count)
        for entry in section.entries {
            let key = entry.key.lowercased()
            if values[key] == nil { values[key] = entry.value }
        }
        return values
    }
}
