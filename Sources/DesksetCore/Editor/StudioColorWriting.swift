import Foundation

/// How the Studio writes a color of an INI widget: where (`ops`), in the file's own notation, and how it is shown
/// before it is written (`preview`). A color that is a `[Variables]` entry is written as that entry, for this widget
/// (`Skin.localTarget`: its own file, after its includes); a color written in the options themselves is replaced in
/// each option that writes it, where that option is defined for this widget. `ColorText` keeps the notation: decimal
/// stays decimal, hex stays hex, and a color the widget adds an alpha to (`#Name#,alpha`) stays R,G,B.
public enum StudioColorWriting {
    /// The color as the file writes it now ("52,199,89", "FFFFFFC8"): what the color field shows.
    public static func currentText(_ role: StudioWidgetFacts.ColorRole, skin: Skin) -> String {
        if let v = role.variable {
            let resolved = skin.resolve("#\(v)#", in: nil, sectionVariables: false)
            if OptionValue.color(resolved) != nil { return resolved }
        }
        for member in role.group.members where member.variableName == nil {
            if OptionValue.color(member.raw) != nil { return member.raw }
        }
        return ColorText.format(role.color, like: nil)
    }

    /// `color` in the notation of `like`, without an alpha when the place cannot take one.
    public static func text(_ color: RGBA, like: String, acceptsAlpha: Bool) -> String {
        var c = color
        if !acceptsAlpha { c.a = 255 }
        var text = ColorText.format(c, like: like)
        if !acceptsAlpha {
            // Three components, whatever `like` had.
            let parts = text.split(separator: ",")
            if parts.count == 4 { text = parts.prefix(3).joined(separator: ",") }
            if !text.contains(","), text.count == 8 { text = String(text.prefix(6)) }
        }
        return text
    }

    /// The edits that give the role `color` in this widget.
    public static func ops(_ role: StudioWidgetFacts.ColorRole, _ color: RGBA, skin: Skin) -> [EditOp] {
        if let v = role.variable {
            guard let target = skin.localTarget(section: "Variables", key: v) else { return [] }
            let value = text(color, like: currentText(role, skin: skin), acceptsAlpha: role.acceptsAlpha)
            return [.setValue(file: target.file, section: target.section, key: v, value: value, afterIncludes: true)]
        }
        var ops: [EditOp] = []
        var done: Set<String> = []
        for (section, key, raw) in literalPlaces(role, skin: skin) {
            guard done.insert("\(section.lowercased())|\(key.lowercased())").inserted,
                  let replaced = ValueUsageIndex.replacingColor(role.color, with: color, in: raw, key: key) else { continue }
            let target = skin.localTarget(section: section, key: key) ?? skin.editTarget(section: section, key: key)
            ops.append(.setValue(file: target.file, section: target.section, key: key, value: replaced,
                                 afterIncludes: false))
        }
        return ops
    }

    /// What shows `color` before it is written: `[Variables]` values, or options of the sections that use the color.
    public static func preview(_ role: StudioWidgetFacts.ColorRole, _ color: RGBA, skin: Skin)
        -> (variables: [String: String], sections: [(String, [String: String])]) {
        if let v = role.variable {
            return ([v: text(color, like: currentText(role, skin: skin), acceptsAlpha: role.acceptsAlpha)], [])
        }
        var sections: [(String, [String: String])] = []
        for use in role.group.members.filter({ $0.variableName == nil }).flatMap(\.uses) {
            guard let section = skin.section(named: use.section), let raw = section.fileOption(use.key),
                  let replaced = ValueUsageIndex.replacingColor(role.color, with: color, in: raw, key: use.key) else { continue }
            if let i = sections.firstIndex(where: { $0.0.caseInsensitiveCompare(use.section) == .orderedSame }) {
                sections[i].1[use.key] = replaced
            } else {
                sections.append((use.section, [use.key: replaced]))
            }
        }
        return ([:], sections)
    }

    /// Where a literal color is written: each option using it, at its look when a look writes it.
    static func literalPlaces(_ role: StudioWidgetFacts.ColorRole, skin: Skin) -> [(String, String, String)] {
        var result: [(String, String, String)] = []
        for use in role.group.members.filter({ $0.variableName == nil }).flatMap(\.uses) {
            if let look = use.look, let raw = skin.styleValues(named: look)?[use.key.lowercased()] {
                result.append((look, use.key, raw))
            } else if let raw = skin.section(named: use.section)?.fileOption(use.key) {
                result.append((use.section, use.key, raw))
            }
        }
        return result
    }
}

/// A color typed or pasted into the color field: `#RGB`, `#RRGGBB`, `#RRGGBBAA` (with or without `#`), what Figma and
/// CSS copy (`rgb(64, 186, 92)`, `rgba(64, 186, 92, 0.5)`, `40BA5C 50%`), and the skin's own `R,G,B[,A]`.
public enum StudioColorInput {
    public static func parse(_ text: String) -> RGBA? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("rgb") {
            guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
            let parts = s[s.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == "/" || $0 == " " })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            var values: [Double] = []
            for (i, p) in parts.enumerated() {
                let percent = p.hasSuffix("%")
                guard let n = Double(percent ? String(p.dropLast()) : p) else { return nil }
                if i == 3 { values.append(percent ? n / 100 * 255 : (n <= 1 ? n * 255 : n)) }
                else { values.append(percent ? n / 100 * 255 : n) }
            }
            guard values.allSatisfy({ $0 >= 0 && $0 <= 255.5 }) else { return nil }
            return RGBA(r: values[0].rounded(), g: values[1].rounded(), b: values[2].rounded(),
                        a: values.count == 4 ? values[3].rounded() : 255)
        }
        // "40BA5C 50%": a hex color and an opacity.
        var alpha: Double?
        if let space = s.lastIndex(of: " "), s.hasSuffix("%"),
           let n = Double(s[s.index(after: space)...].dropLast()), n >= 0, n <= 100 {
            alpha = (n / 100 * 255).rounded()
            s = String(s[..<space]).trimmingCharacters(in: .whitespaces)
        }
        if s.contains(",") {
            guard alpha == nil, var c = OptionValue.color(s) else { return nil }
            let parts = s.split(separator: ",")
            guard parts.count == 3 || parts.count == 4, parts.allSatisfy({ Double($0.trimmingCharacters(in: .whitespaces)) != nil })
            else { return nil }
            c.a = parts.count == 4 ? c.a : 255
            return c
        }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, var c = OptionValue.color(s) else { return nil }
        if let alpha { c.a = alpha }
        return c
    }

    /// `#RRGGBB` (and `AA` when not opaque), as the popover shows a color under its title.
    public static func hex(_ c: RGBA) -> String {
        func h(_ v: Double) -> String { String(format: "%02X", Int(min(max(v, 0), 255).rounded())) }
        return "#" + h(c.r) + h(c.g) + h(c.b) + (c.a < 254.5 ? h(c.a) : "")
    }
}
