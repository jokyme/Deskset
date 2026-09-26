import Foundation

/// Where the value of an option comes from, mirroring the lookup order of `SkinSection.rawOption`.
public enum OptionOrigin: Equatable {
    /// Written in the section itself (location nil only for sections built without a source map).
    case own(IniSourceLocation?)
    /// Inherited from a MeterStyle section.
    case style(String, IniSourceLocation?)
    /// Set at run time by `!SetOption` (not in any file).
    case setOption

    public var location: IniSourceLocation? {
        switch self {
        case .own(let l), .style(_, let l): return l
        case .setOption: return nil
        }
    }
}

/// One option of a section as the inspector shows it.
public struct InspectedOption: Equatable {
    /// Option name as written.
    public var key: String
    /// Value as written (before variables are resolved).
    public var raw: String
    /// Value the engine currently sees (variables and section variables resolved; action options only have
    /// `#Variables#` replaced, like `SkinSection.actionOption`).
    public var resolved: String
    public var origin: OptionOrigin
    /// MeterStyles that also define this option but lose to `origin`.
    public var shadowedStyles: [String]
    /// `#Variables#` named in `raw` (without the `#`), in order of appearance, without duplicates.
    public var variables: [String]
}

/// A `[Variables]` entry as the inspector shows it.
public struct InspectedVariable: Equatable {
    public var name: String
    /// Value as written in the file.
    public var raw: String
    /// Current value (differs from `raw` after `!SetVariable`, or when the definition uses other variables).
    public var current: String
    public var location: IniSourceLocation?
}

/// What kind of section the inspector lists.
public enum InspectedSectionKind: Equatable {
    case rainmeter, variables, metadata, meter, measure
    /// Any other section: a MeterStyle or an unused section.
    case other
}

/// The file and section an edit of an option is written to.
public struct SkinEditTarget: Equatable {
    public var file: URL
    public var section: String
}

extension SkinSection {
    /// Where the current raw value of `key` comes from (nil: the option is not set, its default applies).
    public func optionOrigin(_ key: String) -> OptionOrigin? {
        let lower = key.lowercased()
        var ownRemoved = false
        if let v = overrides[lower] {
            if !v.isEmpty { return .setOption }
            ownRemoved = true
        }
        if !ownRemoved, own.entries.contains(where: { $0.key.lowercased() == lower }) {
            return .own(skin.sources.location(section: name, key: lower))
        }
        for style in styles.reversed() where skin.styleValues(named: style)?[lower] != nil {
            return .style(skin.styleSection(named: style)?.name ?? style, skin.sources.location(section: style, key: lower))
        }
        return nil
    }

    /// Every option that currently has a value: the section's own options in file order, then options inherited
    /// from MeterStyles, then options only set by `!SetOption`.
    public func inspectedOptions() -> [InspectedOption] {
        var keys: [String] = []
        var seen: Set<String> = []
        func add(_ key: String) {
            if seen.insert(key.lowercased()).inserted { keys.append(key) }
        }
        for e in own.entries { add(e.key) }
        for style in styles {
            for e in skin.styleSection(named: style)?.entries ?? [] { add(e.key) }
        }
        for key in overrides.keys.sorted() { add(key) }

        return keys.compactMap { key in
            guard let raw = rawOption(key), let origin = optionOrigin(key) else { return nil }
            let lower = key.lowercased()
            let winningStyle: String? = { if case .style(let s, _) = origin { return s.lowercased() } else { return nil } }()
            let shadowed = styles.reversed().compactMap { style -> String? in
                guard skin.styleValues(named: style)?[lower] != nil, style.lowercased() != winningStyle else { return nil }
                return skin.styleSection(named: style)?.name ?? style
            }
            // Section variables are resolved also for sections without DynamicVariables: the engine resolves them
            // once when the options are read (see `SkinSection.resolvesSectionVariables`), so the current value is
            // what the skin shows, not the raw `[Meter:X]`.
            let resolved = lower.contains("action")
                ? skin.resolveStandardVariables(raw, in: self)
                : skin.resolve(raw, in: self, sectionVariables: true)
            return InspectedOption(key: key, raw: raw, resolved: resolved, origin: origin, shadowedStyles: shadowed,
                                   variables: SkinInspection.referencedVariables(in: raw))
        }
    }
}

extension Skin {
    /// Sections in the order the inspector lists them: `[Rainmeter]`, `[Variables]`, `[Metadata]` (when present),
    /// then every other section in document order.
    public func inspectedSections() -> [(name: String, kind: InspectedSectionKind)] {
        var result: [(String, InspectedSectionKind)] = [("Rainmeter", .rainmeter)]
        for special in ["Variables", "Metadata"] {
            if let s = document.section(named: special) {
                result.append((s.name, special == "Variables" ? .variables : .metadata))
            }
        }
        var seen: Set<String> = ["rainmeter", "variables", "metadata"]
        for s in document.sections where seen.insert(s.name.lowercased()).inserted {
            if let m = meter(named: s.name), m.name.lowercased() == s.name.lowercased() {
                result.append((s.name, .meter))
            } else if measure(named: s.name) != nil {
                result.append((s.name, .measure))
            } else {
                result.append((s.name, .other))
            }
        }
        return result
    }

    /// Options of any section by name: meters, measures and `[Rainmeter]` through `SkinSection.inspectedOptions()`;
    /// other sections (MeterStyles, `[Metadata]`, `[Variables]`) as written, with `#Variables#` resolved.
    public func inspectedOptions(ofSection name: String) -> [InspectedOption] {
        if let s = section(named: name) { return s.inspectedOptions() }
        guard let s = document.section(named: name) else { return [] }
        var seen: Set<String> = []
        return s.entries.compactMap { e in
            guard seen.insert(e.key.lowercased()).inserted else { return nil }
            return InspectedOption(key: e.key, raw: e.value, resolved: resolve(e.value, in: nil, sectionVariables: false),
                                   origin: .own(sources.location(section: s.name, key: e.key)), shadowedStyles: [],
                                   variables: SkinInspection.referencedVariables(in: e.value))
        }
    }

    /// `[Variables]` as written, with current values.
    public func inspectedVariables() -> [InspectedVariable] {
        var seen: Set<String> = []
        return (document.section(named: "Variables")?.entries ?? []).compactMap { e in
            guard seen.insert(e.key.lowercased()).inserted else { return nil }
            return InspectedVariable(name: e.key, raw: e.value, current: variable(e.key) ?? e.value,
                                     location: sources.location(section: "Variables", key: e.key))
        }
    }

    /// The topmost visible meter drawn at the point (skin coordinates). Containers are not drawn, so they are
    /// skipped; meters without an area cannot be picked.
    public func inspectableMeter(at x: Double, _ y: Double) -> Meter? {
        meters.last { !$0.isContainer && $0.frame.width > 0 && $0.frame.height > 0 && $0.isHit(x: x, y: y) }
    }

    /// The skin file and every file it includes.
    public var sourceFiles: [URL] { [fileURL] + includedFiles }

    /// Where an edit of `key` in `section` is written: to the place the current value is defined (the section
    /// itself, possibly in an included file, or the MeterStyle it is inherited from). An option that is not in any
    /// file yet (unset, or only set by `!SetOption`) is added to the section, in the file that holds its header.
    /// `[Variables]` entries go to the file that defines the variable.
    public func editTarget(section name: String, key: String) -> SkinEditTarget {
        let sectionName = document.section(named: name)?.name ?? name
        let headerFile = sources.location(section: sectionName)?.file ?? fileURL
        if let s = section(named: name) {
            switch s.optionOrigin(key) {
            case .own(let l)?: return SkinEditTarget(file: l?.file ?? headerFile, section: s.name)
            case .style(let style, let l)?:
                return SkinEditTarget(file: l?.file ?? sources.location(section: style)?.file ?? fileURL, section: style)
            case .setOption?, nil: return SkinEditTarget(file: headerFile, section: s.name)
            }
        }
        return SkinEditTarget(file: sources.location(section: sectionName, key: key)?.file ?? headerFile,
                              section: sectionName)
    }

    /// Where the files define `key` of `section`, ignoring values set while the skin runs (`!SetOption`, live
    /// previews): the section itself or its MeterStyle; a key no file sets goes to the section's header file. For
    /// rewriting values the user did not touch (renumbering shapes), which must stay what the files say.
    public func fileEditTarget(section name: String, key: String) -> SkinEditTarget {
        let sectionName = document.section(named: name)?.name ?? name
        let headerFile = sources.location(section: sectionName)?.file ?? fileURL
        if let s = section(named: name) {
            switch s.fileOrigin(key) {
            case .own(let l)?: return SkinEditTarget(file: l?.file ?? headerFile, section: s.name)
            case .style(let style, let l)?:
                return SkinEditTarget(file: l?.file ?? sources.location(section: style)?.file ?? fileURL, section: style)
            case .setOption?, nil: return SkinEditTarget(file: headerFile, section: s.name)
            }
        }
        return SkinEditTarget(file: sources.location(section: sectionName, key: key)?.file ?? headerFile,
                              section: sectionName)
    }

    /// Writes `key=value` to `editTarget(section:key:)` (keeping the rest of the file byte for byte) and returns
    /// the target. The skin must be refreshed to see the change.
    @discardableResult
    public func writeOption(section name: String, key: String, value: String) throws -> SkinEditTarget {
        let target = editTarget(section: name, key: key)
        try IniWriter.writeValue(value, key: key, section: target.section, fileURL: target.file)
        return target
    }
}

// MARK: - Editing

extension Skin {
    /// Writes `key=value` into the section itself (never into a MeterStyle), in the file holding the section's
    /// header. Used for geometry edits: dragging one meter must not move every meter sharing its style.
    @discardableResult
    public func writeOwnOption(section name: String, key: String, value: String) throws -> SkinEditTarget {
        let target = ownTarget(section: name, key: key)
        try IniWriter.writeValue(value, key: key, section: target.section, fileURL: target.file)
        return target
    }

    /// Where `writeOwnOption` writes: the section's own definition of the key when it has one (possibly in an
    /// included file), else the file with the section's header.
    public func ownTarget(section name: String, key: String) -> SkinEditTarget {
        let sectionName = section(named: name)?.name ?? document.section(named: name)?.name ?? name
        if let l = sources.location(section: sectionName, key: key) { return SkinEditTarget(file: l.file, section: sectionName) }
        return SkinEditTarget(file: sources.location(section: sectionName)?.file ?? fileURL, section: sectionName)
    }

    /// Where a change meant for this widget alone writes `key` of `section` (docs/editor-friendly.md §7.5, P6): the
    /// section's own definition when one of the widget's own files holds it (`ownTarget`). A definition in a file
    /// other widgets share (`@Resources`) is never rewritten from here; this widget's own .ini holds an override
    /// instead, which wins because it is read after the include (SkinFileLoader rule 5): the section's block there
    /// when it has one, or — for a section that isn't drawn or run (a look, `[Rainmeter]`) — a new block at the end.
    /// nil for a layer or data item only a shared file defines: a block of its own here would move it in the drawing
    /// (or update) order, so it can't change for this widget alone.
    public func localTarget(section name: String, key: String) -> SkinEditTarget? {
        let target = ownTarget(section: name, key: key)
        if isOwnFile(target.file) { return target }
        if let header = sources.location(section: target.section)?.file, isOwnFile(header) {
            return SkinEditTarget(file: header, section: target.section)
        }
        if meter(named: target.section) != nil || measure(named: target.section) != nil { return nil }
        return SkinEditTarget(file: fileURL, section: target.section)
    }

    /// Looks (MeterStyle) layers name that no file defines, each with the layers naming it, in file order.
    public var missingLooks: [(look: String, layers: [String])] {
        var result: [(look: String, layers: [String])] = []
        for m in meters {
            for look in m.styles where styleSection(named: look) == nil {
                if let i = result.firstIndex(where: { $0.look.caseInsensitiveCompare(look) == .orderedSame }) {
                    result[i].layers.append(m.name)
                } else {
                    result.append((look, [m.name]))
                }
            }
        }
        return result
    }

    /// The files an `@Include` names that aren't there (from `loadWarnings`), by file name.
    public var missingIncludeFiles: [String] {
        loadWarnings.compactMap { w -> String? in
            guard let r = w.range(of: "file not found: ") else { return nil }
            let path = w[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
            return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    /// The file other widgets share that defines `key` of `section` (default `[Variables]`), whether or not this
    /// widget's own value overrides it (the theme's color a "This Widget" edit overrides): the last included shared
    /// file defining it; nil when none does.
    public func sharedDefinition(ofVariable key: String, section: String = "Variables") -> URL? {
        for file in includedFiles.reversed() where !isOwnFile(file) {
            guard let text = try? TextDecoding.readFileDetectingEncoding(at: file).text,
                  IniDocument.parse(text).section(named: section)?.value(forKey: key) != nil else { continue }
            return file
        }
        return nil
    }

    /// `sharedDefinition` of a `[Rainmeter]` key.
    public func sharedRainmeterDefinition(_ key: String) -> URL? { sharedDefinition(ofVariable: key, section: "Rainmeter") }

    /// Shows option values without writing them (the editor's live preview while dragging or picking a color):
    /// they act like `!SetOption` values until `endPreview`. Re-reads the section and recomputes the layout.
    public func preview(section name: String, _ values: [String: String]) {
        assertOwned()
        guard let s = section(named: name) else { return }
        for (key, value) in values {
            let lower = key.lowercased()
            if previewSaved[s.name.lowercased()]?[lower] == nil {
                previewSaved[s.name.lowercased(), default: [:]][lower] = .some(s.overrides[lower])
            }
            // An empty override means "option removed"; a preview of an empty value shows the default instead.
            s.overrides[lower] = value.isEmpty ? "" : value
        }
        s.needsOptionRead = true
        s.readOptionsIfNeeded()
        if s is Meter { s.skin.meters.forEach { $0.updateMeter() } }
        layout()
        redraw()
    }

    /// Previews `[Variables]` values (color picking on a theme variable).
    public func previewVariables(_ values: [String: String]) {
        assertOwned()
        for (key, value) in values {
            let lower = key.lowercased()
            if previewSavedVariables[lower] == nil { previewSavedVariables[lower] = .some(variable(key)) }
            setVariable(key, value)
        }
        for m in measures { m.needsOptionRead = true; m.readOptionsIfNeeded() }
        for m in meters { m.needsOptionRead = true; m.readOptionsIfNeeded(); m.updateMeter() }
        layout()
        redraw()
    }

    /// Drops every preview value, restoring what was there before (including real `!SetOption` values).
    public func endPreview() {
        assertOwned()
        for (sectionKey, saved) in previewSaved {
            guard let s = section(named: sectionKey) else { continue }
            for (key, old) in saved { s.overrides[key] = old }
            s.needsOptionRead = true
            s.readOptionsIfNeeded()
        }
        for (key, old) in previewSavedVariables {
            if let old { setVariable(key, old) }
        }
        let hadPreview = !previewSaved.isEmpty || !previewSavedVariables.isEmpty
        previewSaved = [:]
        previewSavedVariables = [:]
        if hadPreview {
            for m in meters { m.needsOptionRead = true; m.readOptionsIfNeeded(); m.updateMeter() }
            layout()
            redraw()
        }
    }

    public var isPreviewing: Bool { !previewSaved.isEmpty || !previewSavedVariables.isEmpty }
}

extension Meter {
    /// Raw `X`, `Y`, `W`, `H` for the editor (as written, `!SetOption` and MeterStyles included).
    public var rawGeometry: (x: String?, y: String?, w: String?, h: String?) {
        (rawOption("X"), rawOption("Y"), rawOption("W"), rawOption("H"))
    }

    /// Width / height of the content (frame minus padding): the base for resizing a meter without `W` / `H`.
    public var contentSize: (width: Double, height: Double) {
        (max(frame.width - padding.left - padding.right, 0), max(frame.height - padding.top - padding.bottom, 0))
    }
}

public enum SkinInspection {
    /// `#Name#` references in a raw value, in order and without duplicates. `#*Name*#` escapes are skipped.
    public static func referencedVariables(in raw: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        let scalars = Array(raw.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "#" else { i += 1; continue }
            var j = i + 1
            while j < scalars.count, scalars[j] != "#", !IniSyntax.isBlank(scalars[j]), scalars[j] != "[",
                  scalars[j] != "]", scalars[j] != "\n" {
                j += 1
            }
            if j < scalars.count, scalars[j] == "#", j > i + 1 {
                var name = String(String.UnicodeScalarView(scalars[(i + 1)..<j]))
                if name.hasPrefix("*") && name.hasSuffix("*") {
                    name = ""
                }
                if !name.isEmpty {
                    if seen.insert(name.lowercased()).inserted { result.append(name) }
                }
                i = j + 1
            } else {
                i = j > i + 1 ? j : i + 1
            }
        }
        return result
    }
}
