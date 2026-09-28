import Foundation

/// What a patch of a running skin changed (`Skin.patch(sources:)`).
public struct SkinPatchSummary: Equatable {
    /// Sections whose options in the files changed — their own, a MeterStyle's they use, or a variable they use — in
    /// file order.
    public var changedSections: [String]
    /// `[Variables]` whose definition changed (lowercased), sorted.
    public var changedVariables: [String]
    /// Whether `[Metadata]` changed.
    public var metadataChanged: Bool
    /// Sections whose options were read again, in file order: the changed ones, and the ones that follow other
    /// sections (DynamicVariables, section variables).
    public var readAgain: [String]
    /// `Skin.sourceGeneration` after the patch.
    public var sourceGeneration: Int

    /// Only the text changed, not what the skin shows: comments, blank lines, the order or spelling of keys.
    public var isTextOnly: Bool { changedSections.isEmpty && changedVariables.isEmpty && !metadataChanged }
}

/// Why a patch cannot be applied to the running skin, which must load again instead.
public enum SkinPatchReason: Equatable, CustomStringConvertible {
    /// The skin was closed.
    case closed
    /// The main file cannot be read.
    case unreadable(String)
    /// Other files are included, or including them went differently (a missing file…).
    case includes
    /// Sections were added, removed, renamed or put in another order.
    case sections
    /// A section's `Meter=` or `Measure=` changed.
    case type(section: String)
    /// A `[Rainmeter]` option changed (it is read when the skin loads), directly or through a variable.
    case rainmeter(key: String)
    /// An option changed that is not live for its section (`LiveOptions`).
    case option(section: String, key: String)
    /// A meter's MeterStyle changed to a list that names variables or section variables.
    case meterStyle(section: String)
    /// A measure that averages its values changed.
    case averaged(section: String)
    /// A `[Variables]` definition changed in a skin with scripts, which may have read it.
    case scriptsReadVariables
    /// A measure that must read section variables again cannot be read again safely.
    case sectionVariables(section: String)

    public var description: String {
        switch self {
        case .closed: return "the skin is closed"
        case .unreadable(let message): return "the file cannot be read (\(message))"
        case .includes: return "the included files changed"
        case .sections: return "sections were added, removed, renamed or moved"
        case .type(let section): return "the type of [\(section)] changed"
        case .rainmeter(let key): return "[Rainmeter] \(key) changed"
        case .option(let section, let key): return "\(key) of [\(section)] needs a reload"
        case .meterStyle(let section): return "the MeterStyle of [\(section)] names variables"
        case .averaged(let section): return "[\(section)] averages its values"
        case .scriptsReadVariables: return "a variable changed and scripts may have read it"
        case .sectionVariables(let section): return "[\(section)] reads section variables and cannot be read again"
        }
    }
}

public enum SkinPatchResult: Equatable {
    case applied(SkinPatchSummary)
    case needsReload(SkinPatchReason)
}

extension Skin {
    /// Gives the running skin the text `sources` holds for its files, without loading it again when the change allows
    /// it: the Studio's value edits show at once, and what the skin has shown so far stays — graph history (of the
    /// measures the graphs still read), the Calc counter, variables set while it runs (whose definition did not change),
    /// `!SetOption` values of options the files did not change, hover and bang states, editor previews (a patch replaces
    /// only what the files say).
    ///
    /// The change is applied when the same files are included, the sections are the same ones in the same order with
    /// the same `Meter=` / `Measure=`, and every option that changed is live for its section (`LiveOptions`) — also
    /// where a changed MeterStyle or variable reaches. Then each section takes its new text; changed `[Variables]` are
    /// resolved again (the new definition wins over a value set while the skin ran); an option that changed drops its
    /// `!SetOption` value; the sections that changed are read, a changed measure updates (as `!UpdateMeasure` would,
    /// without OnChangeAction), the meters take the new values, and the sections that changed or follow others
    /// (DynamicVariables, section variables such as `[Meter:X]` or `[Measure]`) are read again in file order, so each
    /// one sees the values and frames before it; graphs add no sample (their next update does), and a line that reads
    /// another measure now starts afresh; the skin is laid out, sized again and redrawn.
    /// `sourceGeneration` moves on even when only comments changed (where things are written moved).
    ///
    /// Otherwise nothing changes and the result says why the skin must load again.
    public func patch(sources: SourceProvider) -> SkinPatchResult {
        assertOwned()
        guard !isClosed else { return .needsReload(.closed) }
        let builtins = builtInVariables()
        var includesAppearance = false
        let loaded: LoadedIniFile
        do {
            // As `load()` expands include paths.
            loaded = try SkinFileLoader.load(url: fileURL, sources: sources) { raw, readSoFar in
                let table = builtins.merging(readSoFar) { _, new in new }
                return VariableResolver(variableLookup: { name in
                    let key = name.lowercased()
                    if BuiltInVariables.isMacAppearanceKey(key) {
                        includesAppearance = true
                        return builtins[key]
                    }
                    return table[key]
                }).resolve(raw)
            }
        } catch {
            return .needsReload(.unreadable("\(error)"))
        }
        let plan: PatchPlan
        switch planPatch(loaded) {
        case .failure(let reason): return .needsReload(reason)
        case .success(let p): plan = p
        }
        let ownAction = loaded.document.section(named: "Rainmeter")?.value(forKey: "MacOnAppearanceChangeAction")
        let mentionsAppearance = includesAppearance
            || !(ownAction?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            || loaded.document.sections.contains { $0.entries.contains { SkinAppearance.mentioned(in: $0.value) } }
        return .applied(apply(plan, loaded, mentionsAppearance: mentionsAppearance))
    }

    // MARK: Planning

    private struct PatchPlan {
        /// The new text of each section, by lowercased name.
        var sections: [String: IniSection]
        /// Sections whose options changed, with the lowercased keys that changed.
        var changed: [ObjectIdentifier: Set<String>]
        /// Other sections to read again (DynamicVariables, section variables).
        var readAgain: Set<ObjectIdentifier>
        var variables: [String: String?]
        var metadataChanged: Bool
    }

    private enum PlanResult {
        case success(PatchPlan)
        case failure(SkinPatchReason)
    }

    private func planPatch(_ loaded: LoadedIniFile) -> PlanResult {
        func paths(_ urls: [URL]) -> [String] { urls.map { $0.standardizedFileURL.path } }
        guard paths(loaded.includedFiles) == paths(includedFiles), loaded.warnings == loadWarnings else {
            return .failure(.includes)
        }
        let oldSections = document.sections
        let newSections = loaded.document.sections
        guard oldSections.count == newSections.count,
              zip(oldSections, newSections).allSatisfy({ $0.name == $1.name }) else { return .failure(.sections) }

        // What each section's own text changed.
        var ownChanges: [String: Set<String>] = [:]
        var newIndex: [String: IniSection] = [:]
        for (old, new) in zip(oldSections, newSections) {
            let key = new.name.lowercased()
            if newIndex[key] == nil { newIndex[key] = new }
            guard old != new else { continue }
            if old.value(forKey: "Measure") != new.value(forKey: "Measure")
                || old.value(forKey: "Meter") != new.value(forKey: "Meter") {
                return .failure(.type(section: new.name))
            }
            let a = SkinSection.index(old), b = SkinSection.index(new)
            let keys = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }
            if !keys.isEmpty { ownChanges[key, default: []].formUnion(keys) }
        }

        // `[Variables]` resolved again from the new text, with the built-in values the loaded ones had.
        var variables: [String: String?] = [:]
        if ownChanges["variables"] != nil {
            let (defined, definitionBuiltins) = variableDefinitions
            let fresh = VariableResolver.resolveDefinitions(newIndex["variables"]?.entries ?? [],
                                                            builtins: definitionBuiltins)
            for key in Set(fresh.keys).union(defined.keys) where fresh[key] != defined[key] {
                variables[key] = .some(fresh[key])
            }
            if !variables.isEmpty, measures.contains(where: { $0.type == "script" }) {
                return .failure(.scriptsReadVariables)
            }
        }
        let changedNames = Set(variables.keys)

        var newStyleCache: [String: [String: String]] = [:]
        func newStyleValues(_ name: String) -> [String: String]? {
            let key = name.lowercased()
            if key == "rainmeter" || key == "variables" || key == "metadata" { return nil }
            if let cached = newStyleCache[key] { return cached }
            guard let section = newIndex[key] else { return nil }
            let values = SkinSection.index(section)
            newStyleCache[key] = values
            return values
        }

        var changed: [ObjectIdentifier: Set<String>] = [:]
        let sections: [SkinSection] = (rainmeterSection.map { [$0] } ?? []) + (measures as [SkinSection])
            + (meters as [SkinSection])
        for section in sections {
            let lower = section.name.lowercased()
            var keys = ownChanges[lower] ?? []
            // Nothing it reads changed: its own text, the styles it uses and the variables are as they were.
            if keys.isEmpty, changedNames.isEmpty,
               !((section as? Meter)?.styles.contains { ownChanges[$0.lowercased()] != nil } ?? false) { continue }
            let newOwn = SkinSection.index(newIndex[lower] ?? IniSection(name: section.name))
            var newStyles: [String] = []
            if let meter = section as? Meter {
                newStyles = meter.styles
                // MeterStyle is read from the meter itself (or `!SetOption`), never from a style.
                let styleChanged = keys.contains("meterstyle")
                    || (!changedNames.isEmpty && Skin.mentions(newOwn["meterstyle"] ?? "", changedNames))
                // A `!SetOption` MeterStyle gives way to the file's new one (`apply` drops it, as a reload would).
                if styleChanged {
                    let raw = newOwn["meterstyle"] ?? ""
                    if raw.contains("#") || raw.contains("[") { return .failure(.meterStyle(section: meter.name)) }
                    newStyles = OptionValue.list(raw)
                }
                let oldOwn = SkinSection.index(meter.own)
                var candidates = keys
                if newStyles.map({ $0.lowercased() }) != meter.styles.map({ $0.lowercased() }) {
                    for style in meter.styles { candidates.formUnion(styleValues(named: style)?.keys ?? [:].keys) }
                    for style in newStyles { candidates.formUnion(newStyleValues(style)?.keys ?? [:].keys) }
                } else {
                    for style in meter.styles { candidates.formUnion(ownChanges[style.lowercased()] ?? []) }
                }
                keys = candidates.filter { key in
                    key == "meterstyle" && keys.contains(key)
                        || Skin.fileValue(key, own: oldOwn, styles: meter.styles, style: styleValues(named:))
                            != Skin.fileValue(key, own: newOwn, styles: newStyles, style: newStyleValues)
                }
            }
            // Options that use a changed variable are read again too.
            if !changedNames.isEmpty {
                var used = Set(newOwn.keys)
                for style in newStyles { used.formUnion(newStyleValues(style)?.keys ?? [:].keys) }
                for key in used where !keys.contains(key) {
                    let raw = section is Meter
                        ? Skin.fileValue(key, own: newOwn, styles: newStyles, style: newStyleValues) : newOwn[key]
                    if let raw, Skin.mentions(raw, changedNames) { keys.insert(key) }
                }
            }
            guard !keys.isEmpty else { continue }
            let kind = liveKind(of: section)
            for key in keys.sorted() where LiveOptions.applies(key, in: kind) == .reload {
                return .failure(kind == .rainmeter ? .rainmeter(key: key) : .option(section: section.name, key: key))
            }
            if let measure = section as? Measure, measure.averageSize > 1 {
                return .failure(.averaged(section: measure.name))
            }
            changed[ObjectIdentifier(section)] = keys
        }

        // Sections that follow others are read again after the changed ones.
        var readAgain: Set<ObjectIdentifier> = []
        if !changed.isEmpty {
            for section in (measures as [SkinSection]) + (meters as [SkinSection])
            where changed[ObjectIdentifier(section)] == nil {
                if section.dynamicVariables {
                    // Read on every update anyway. A measure of another type is left to its next update: with an
                    // UpdateDivider that may be a while, and reading it now could start its work early (a download).
                    if let measure = section as? Measure,
                       !LiveOptions.canReadAgain(measureType: Skin.liveMeasureType(measure)) { continue }
                    readAgain.insert(ObjectIdentifier(section))
                } else if section.mentionsSectionVariables {
                    if let measure = section as? Measure,
                       !LiveOptions.canReadAgain(measureType: Skin.liveMeasureType(measure)) {
                        return .failure(.sectionVariables(section: measure.name))
                    }
                    readAgain.insert(ObjectIdentifier(section))
                }
            }
        }
        return .success(PatchPlan(sections: newIndex, changed: changed, readAgain: readAgain, variables: variables,
                                  metadataChanged: ownChanges["metadata"] != nil))
    }

    /// What a section is, for `LiveOptions`.
    func liveKind(of section: SkinSection) -> LiveOptions.Section {
        if section is RainmeterSection { return .rainmeter }
        if let meter = section as? Meter { return .meter(type: meter is UnsupportedMeter ? "unsupported" : meter.type) }
        if let measure = section as? Measure { return .measure(type: Skin.liveMeasureType(measure)) }
        return .other
    }

    /// The `LiveOptions` type of a measure: its class decides (a `Plugin=Calc` is no Calc measure), and a class the
    /// table does not know gets a name the table has no entry for.
    static func liveMeasureType(_ measure: Measure) -> String {
        switch measure {
        case is CalcMeasure: return "calc"
        case is TimeMeasure: return "time"
        case is UptimeMeasure: return "uptime"
        case is CPUMeasure: return "cpu"
        case is StringMeasure: return "string"
        default: return "(\(measure.type))"
        }
    }

    /// `key` as the files give it to a section with these own options and MeterStyles — `SkinSection.fileOption`'s
    /// rule: the own value unless empty, then the styles, the last listed first; `""` when only empty values are set.
    static func fileValue(_ key: String, own: [String: String], styles: [String],
                          style: (String) -> [String: String]?) -> String? {
        var foundEmpty = false
        if let v = own[key] {
            if !v.isEmpty { return v }
            foundEmpty = true
        }
        for name in styles.reversed() {
            if let v = style(name)?[key] {
                if !v.isEmpty { return v }
                foundEmpty = true
            }
        }
        return foundEmpty ? "" : nil
    }

    /// Whether `raw` uses one of the variables `names` (lowercased): `#Name#` or `[#Name]`. A nested name
    /// (`[#Color[#Index]]`) may be any variable, so it counts as using each of them.
    static func mentions(_ raw: String, _ names: Set<String>) -> Bool {
        guard !names.isEmpty, raw.utf8.contains(UInt8(ascii: "#")) else { return false }
        let text = raw.lowercased()
        for name in names where text.contains("#\(name)#") || text.contains("[#\(name)]") { return true }
        var rest = Substring(text)
        while let open = rest.range(of: "[#") {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: "]") else { break }
            if after[..<close].contains("[") || after[..<close].contains("#") { return true }
            rest = after[close...]
        }
        return false
    }

    // MARK: Applying

    private func apply(_ plan: PatchPlan, _ loaded: LoadedIniFile, mentionsAppearance: Bool) -> SkinPatchSummary {
        sourceGeneration &+= 1
        installPatchedSource(loaded, mentionsAppearance: mentionsAppearance)
        if !plan.variables.isEmpty { redefineVariables(plan.variables) }
        let ordered: [SkinSection] = (measures as [SkinSection]) + (meters as [SkinSection])
        if let root = rainmeterSection {
            let section = plan.sections["rainmeter"] ?? IniSection(name: "Rainmeter")
            if root.own != section { root.own = section }
        }
        for section in ordered {
            if let new = plan.sections[section.name.lowercased()], section.own != new { section.own = new }
        }
        var summary = SkinPatchSummary(
            changedSections: ((rainmeterSection.map { [$0] } ?? []) + ordered)
                .filter { plan.changed[ObjectIdentifier($0)] != nil }.map(\.name),
            changedVariables: plan.variables.keys.sorted(), metadataChanged: plan.metadataChanged, readAgain: [],
            sourceGeneration: sourceGeneration)
        guard !plan.changed.isEmpty else { return summary }

        // A key the files changed drops its `!SetOption` value (a hover action's, `!MoveMeter`'s), as a reload drops it:
        // the edit shows. An editor preview of the key goes on, and ends on the file's value.
        for section in ordered {
            guard let keys = plan.changed[ObjectIdentifier(section)] else { continue }
            let sectionKey = section.name.lowercased()
            for key in keys {
                if previewSaved[sectionKey]?[key] != nil {
                    previewSaved[sectionKey]?[key] = .some(nil)
                } else {
                    section.overrides.removeValue(forKey: key)
                }
            }
        }
        // The measures the graphs read, to tell which lines read another one after the patch.
        var graphMeasures: [ObjectIdentifier: [Measure?]] = [:]
        for meter in meters {
            if let line = meter as? LineMeter {
                graphMeasures[ObjectIdentifier(meter)] = line.boundMeasures
            } else if let histogram = meter as? HistogramMeter {
                graphMeasures[ObjectIdentifier(meter)] = histogram.boundMeasures
            }
        }

        // The changed sections, in file order (measures first, as an update reads them); whether they name measures or
        // meters in brackets is found anew, as a reload's load-time read finds it.
        for section in ordered where plan.changed[ObjectIdentifier(section)] != nil {
            section.rereadTrackingSectionVariables()
        }
        // A changed measure shows its new options now, as `!UpdateMeasure` would (its IfConditions may run), before
        // anything reads its value — a reload too updates the measures before it reads what follows them. Its new
        // string is no change for OnChangeAction, as it is none after a reload. A change of how the string is written
        // (Substitute) or of the groups shows without an update: a Calc that counts its updates or rolls a Random would
        // count one more.
        for measure in measures {
            guard let keys = plan.changed[ObjectIdentifier(measure)],
                  !keys.isSubset(of: LiveOptions.measureGeneral) else { continue }
            measure.forgetChangeBaseline()
            perform(Bang(name: "updatemeasure", args: [measure.name]))
            if isClosed { return summary }
        }
        // The meters take the new values, so their text and size are right before anything reads a frame.
        for meter in meters where !Skin.addsSamples(meter) { meter.updateMeter() }
        // Everything that may follow another section, again in file order, each meter taking its values as it is read
        // (as an update does); the frames are laid out anew before the next read of one, so a section sees the new
        // places and sizes of the ones before it.
        for section in ordered
        where plan.changed[ObjectIdentifier(section)] != nil || plan.readAgain.contains(ObjectIdentifier(section)) {
            markLayoutPending()
            section.needsOptionRead = true
            section.readOptionsIfNeeded()
            if let meter = section as? Meter, !Skin.addsSamples(meter) { meter.updateMeter() }
            summary.readAgain.append(section.name)
        }
        for meter in meters {
            if let before = graphMeasures[ObjectIdentifier(meter)] {
                (meter as? LineMeter)?.restartLines(readingOtherThan: before)
                (meter as? HistogramMeter)?.restartSides(readingOtherThan: before)
            }
            meter.noteDrawChange()
        }
        finishPatch()
        return summary
    }

    /// Meters whose `updateMeter` records a sample (Line, Histogram): a patch leaves that to their next update.
    static func addsSamples(_ meter: Meter) -> Bool {
        meter is LineMeter || meter is HistogramMeter
    }
}
