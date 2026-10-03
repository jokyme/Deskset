import CoreText
import DeskLanguage
import DesksetCore
import Foundation

/// The language checker's platform fonts. Mutable font indexes remain under the existing Fonts lock.
struct DeskFontCatalog: FontCataloging {
    private static let designs = ["System", "System Rounded", "System Mono", "System Serif"]
    // These are Mac aliases in Fonts' substitution table, not Windows families.
    private static let systemAliases: Set<String> = [
        "system font", "system-ui", "-apple-system", "san francisco", "sf pro", "sf pro text",
        "sf pro display", ".sf ns",
    ]

    func isInstalled(family: String) -> Bool {
        guard let name = Self.name(family) else { return false }
        return Fonts.installedFamily(named: name) != nil || Self.isSystemName(name)
    }

    func macSubstitute(forWindowsFamily family: String) -> String? {
        guard let name = Self.name(family), !isInstalled(family: name) else { return nil }
        return Fonts.substitution(for: name)
    }

    func similarFamilies(to family: String) -> [String] {
        guard let name = Self.name(family), !isInstalled(family: name),
              let best = IniDiagnostics.closest(to: name, in: candidates()) else { return [] }
        return [best]
    }

    func families(matching prefix: String, limit: Int) -> [String] {
        guard limit > 0, !prefix.contains("\0") else { return [] }
        let key = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        let names = candidates()
        if key.isEmpty {
            let designs = Set(Self.designs)
            return Array((Self.designs + names.filter { !designs.contains($0) }).prefix(limit))
        }
        let matches = names.compactMap { name -> (name: String, rank: Int)? in
            let lowered = name.lowercased()
            if lowered == key { return (name, 0) }
            if lowered.hasPrefix(key) { return (name, 1) }
            if lowered.split(whereSeparator: { $0.isWhitespace }).contains(where: { $0.hasPrefix(key) }) {
                return (name, 2)
            }
            return nil
        }
        return Array(matches.sorted {
            $0.rank == $1.rank ? $0.name < $1.name : $0.rank < $1.rank
        }.prefix(limit).map(\.name))
    }

    private func candidates() -> [String] {
        Array(Set(Fonts.installedFamilyNames + Self.designs)).sorted()
    }

    private static func name(_ family: String) -> String? {
        let name = family.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.contains("\0") ? nil : name
    }

    private static func isSystemName(_ name: String) -> Bool {
        Fonts.systemDesign(named: name) != nil || systemAliases.contains(name.lowercased())
    }
}

/// Reads the supplied bytes only. Creating descriptors does not register fonts for name matching.
struct DeskFontFileInspector: FontFileInspecting {
    func families(inFontData data: Data, fileName _: String) -> [String]? {
        guard !data.isEmpty,
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              !descriptors.isEmpty else { return nil }
        var families = Set<String>()
        for descriptor in descriptors {
            guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  !family.isEmpty else { return nil }
            families.insert(family)
        }
        return families.sorted()
    }
}
