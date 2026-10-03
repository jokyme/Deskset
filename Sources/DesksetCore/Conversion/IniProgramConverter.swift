import Foundation

/// Initial, deliberately bounded compatibility conversion. Rejection is a capability result, not a claim that
/// the input is invalid Rainmeter or unsafe. No kernel is constructed until its complete source is preflighted.
package enum IniProgramConverter {
    package static func convert(config: String, fileURL: URL, skinsDirectory: URL,
                                system: SystemDataSource, environment: SkinEnvironment,
                                clock: SkinClock, executor: VirtualTimeExecutor,
                                effects: RecordingSideEffects) throws -> RainmeterProgram {
        precondition(executor.isCurrent)
        weak var temporary: Skin?
        let program = try load(config: config, fileURL: fileURL, skinsDirectory: skinsDirectory, system: system,
                               environment: environment, clock: clock, executor: executor, effects: effects) {
            temporary = $0
        }
        guard temporary == nil else { throw RainmeterProgramError.inconsistentFrozenInput }
        return program
    }

    private static func load(config: String, fileURL: URL, skinsDirectory: URL, system: SystemDataSource,
                             environment: SkinEnvironment, clock: SkinClock, executor: VirtualTimeExecutor,
                             effects: RecordingSideEffects, observe: (Skin) -> Void) throws -> RainmeterProgram {
        let bytes = try Data(contentsOf: fileURL)
        let text = TextDecoding.decode(bytes)
        let document = IniDocument.parse(text)
        let frozen = FrozenSource(file: fileURL, text: text)
        // Reject directives before the loader can resolve or open an include path.
        for section in IniSyntax.parseFile(text).sections {
            for (index, entry) in section.entries.enumerated() where entry.key.lowercased().hasPrefix("@include") {
                throw RainmeterProgramError.outsideInitialProfile(section: section.name, key: entry.key,
                    source: RainmeterProgram.Source(file: fileURL, line: section.entryLines[index]), reason: "includes")
            }
        }
        let loaded = try SkinFileLoader.load(url: fileURL, sources: frozen) { raw, _ in raw }
        guard loaded.document == document, loaded.includedFiles.isEmpty, loaded.warnings.isEmpty else {
            throw RainmeterProgramError.inconsistentFrozenInput
        }
        let inner = EnvironmentHost(environment)
        let host = RecordingSkinHost(effects: effects, inner: inner)
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: skinsDirectory, system: system, host: host)
        observe(skin)
        skin.runInVirtualTime(executor)
        skin.skinClock = clock
        skin.sideEffects = effects
        skin.sourceProvider = frozen
        skin.random = SkinRandom(seed: 1)
        defer { skin.close() }
        let builtins = skin.builtInVariables()
        let kernels = try preflight(document, sources: loaded.sources, builtins: builtins)
        // Skin consults extension registrations before built-ins. This profile qualifies the exact Time kernel,
        // so a substituted implementation must be declined before the temporary Skin can instantiate it.
        if kernels.values.contains(.time), let registered = MeasureRegistry.measure(named: "time"),
           ObjectIdentifier(registered) != ObjectIdentifier(TimeMeasure.self) {
            let section = document.sections.first { kernels[$0.name.lowercased()] == .time }
            let source = section.flatMap { loaded.sources.location(section: $0.name, key: "Measure") }
                .map { RainmeterProgram.Source(file: $0.file, line: $0.line) }
            throw RainmeterProgramError.outsideInitialProfile(section: section?.name ?? "", key: "Measure",
                                                              source: source, reason: "registered measure implementation")
        }
        let fonts = skin.resourcesDirectory.appendingPathComponent("Fonts", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: fonts.path), names.contains(where: {
            !$0.hasPrefix(".") && RmskinPlainArchive.fontExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }) {
            throw RainmeterProgramError.outsideInitialProfile(section: "Rainmeter", key: "LocalFont", source: nil,
                                                              reason: "automatic font resources")
        }
        let effectsBefore = effects.records
        let pendingBefore = executor.pendingCount
        try skin.load()
        guard skin.measures.count == kernels.values.filter({ $0 == .time }).count,
              skin.measures.allSatisfy({ ObjectIdentifier(type(of: $0)) == ObjectIdentifier(TimeMeasure.self) }),
              skin.meters.count == kernels.values.filter({ $0 == .string || $0 == .image }).count,
              skin.document == document, skin.sources == loaded.sources, skin.includedFiles.isEmpty,
              skin.updateCount == 0, skin.counter == 0, effects.records == effectsBefore,
              executor.pendingCount == pendingBefore, !frozen.unexpectedRequest, skin.settings.localFonts.isEmpty, !inner.unexpectedMetricRead else {
            throw RainmeterProgramError.inconsistentFrozenInput
        }
        func location(_ value: IniSourceLocation?) -> RainmeterProgram.Source? {
            value.map { RainmeterProgram.Source(file: $0.file, line: $0.line) }
        }
        return RainmeterProgram(config: config, fileURL: fileURL, skinsDirectory: skinsDirectory,
                                resourcesDirectory: skin.resourcesDirectory, sourceBytes: bytes,
                                sections: skin.document.sections.map { section in
            RainmeterProgram.Section(name: section.name, entries: section.entries.map { entry in
                RainmeterProgram.Entry(key: entry.key, value: entry.value,
                                       source: location(skin.sources.location(section: section.name, key: entry.key)))
            }, source: location(skin.sources.location(section: section.name)), kernel: kernels[section.name.lowercased()])
        }, staticBuiltins: builtins,
        window: RainmeterProgram.Window(updateMilliseconds: skin.settings.update,
                                        backgroundMode: skin.settings.backgroundMode, solidColor: skin.settings.solidColor))
    }

    private static func preflight(_ document: IniDocument, sources: IniSourceMap,
                                  builtins: [String: String]) throws -> [String: RainmeterProgram.Kernel] {
        let rootKeys: Set<String> = ["update", "backgroundmode", "solidcolor"]
        let common: Set<String> = ["x", "y", "w", "h", "solidcolor", "antialias", "meterstyle", "updatedivider", "hidden"]
        let stringKeys = common.union(["meter", "measurename", "text", "fontface", "fontsize", "fontcolor",
                                       "stringstyle", "stringalign", "stringcase"])
        let imageKeys = common.union(["meter", "imagename"])
        let timeKeys: Set<String> = ["measure", "format", "updatedivider"]
        let numeric: Set<String> = ["x", "y", "w", "h", "fontsize", "updatedivider", "hidden", "antialias", "update"]
        let staticNames: Set<String> = ["@", "currentpath", "currentfile", "currentconfig", "rootconfig",
                                       "rootconfigpath", "skinspath", "crlf", "currentsection"]
        let definitions = document.section(named: "Variables")?.entries ?? []
        let ownNames = Set(definitions.map { $0.key.lowercased() })
        let variables = VariableResolver.resolveDefinitions(definitions, builtins: builtins)
        func decline(_ section: IniSection, _ entry: IniEntry, _ reason: String) -> RainmeterProgramError {
            let source = sources.location(section: section.name, key: entry.key)
                .map { RainmeterProgram.Source(file: $0.file, line: $0.line) }
            return .outsideInitialProfile(section: section.name, key: entry.key, source: source, reason: reason)
        }
        func value(_ entry: IniEntry, in section: IniSection) throws -> String {
            // This first profile excludes bracket/escaped/event syntax rather than introducing another evaluator.
            guard !entry.value.contains("["), !entry.value.contains("$"), !entry.value.contains("#*") else {
                throw decline(section, entry, "dynamic or escaped template capability")
            }
            var rejected = false
            let resolver = VariableResolver(variableLookup: { name in
                let key = name.lowercased()
                if !staticNames.contains(key) && (!ownNames.contains(key) || builtins[key] != nil) { rejected = true }
                if key == "currentsection" { return section.name }
                return variables[key] ?? builtins[key]
            })
            let result = resolver.resolve(entry.value)
            guard !rejected, !result.contains("["), !result.contains("$"), !result.contains("#") else {
                throw decline(section, entry, "unresolved or dynamic variable")
            }
            return result
        }
        var kernels: [String: RainmeterProgram.Kernel] = [:]
        for section in document.sections {
            let name = section.name.lowercased()
            if name == "metadata" { continue }
            let allowed: Set<String>
            if name == "variables" { allowed = Set(section.entries.map { $0.key.lowercased() }) }
            else if name == "rainmeter" { allowed = rootKeys }
            else if let raw = section.entries.first(where: { $0.key.lowercased() == "measure" }) {
                guard raw.value.lowercased() == "time" else { throw decline(section, raw, "measure type") }
                kernels[name] = .time; allowed = timeKeys
            } else if let raw = section.entries.first(where: { $0.key.lowercased() == "meter" }) {
                switch raw.value.lowercased() {
                case "string": kernels[name] = .string; allowed = stringKeys
                case "image": kernels[name] = .image; allowed = imageKeys
                default: throw decline(section, raw, "meter type")
                }
            } else { allowed = stringKeys.union(imageKeys).subtracting(["meter"]) }
            for entry in section.entries {
                let key = entry.key.lowercased()
                guard allowed.contains(key) else { throw decline(section, entry, "option capability") }
                let resolved = try value(entry, in: section)
                if name != "variables", numeric.contains(key) {
                    let number = (key == "x" || key == "y") && (resolved.hasSuffix("r") || resolved.hasSuffix("R"))
                        ? String(resolved.dropLast()) : resolved
                    if !number.isEmpty, OptionValue.number(number) == nil {
                        throw decline(section, entry, "nonconstant numeric expression")
                    }
                }
                if key == "imagename", !resolved.isEmpty { throw decline(section, entry, "image resource") }
                if name == "rainmeter", key == "backgroundmode", ![1.0, 2.0].contains(OptionValue.number(resolved) ?? -1) {
                    throw decline(section, entry, "background resource mode")
                }
            }
        }
        // Names must refer to existing static definitions; missing data is a decline, never an empty success.
        for section in document.sections where kernels[section.name.lowercased()] != nil {
            let options = OptionStack(own: section)
            if let styleEntry = section.entries.first(where: { $0.key.lowercased() == "meterstyle" }) {
                options.styles = OptionValue.list(try value(styleEntry, in: section))
                for name in options.styles {
                    guard document.section(named: name) != nil, kernels[name.lowercased()] == nil else {
                        throw decline(section, styleEntry, "missing or non-style parent")
                    }
                }
            }
            let measureName = options.rawOption("MeasureName", styleValues: { name in
                document.section(named: name).map(OptionStack.index)
            })
            if let raw = measureName, !raw.isEmpty {
                let entry = IniEntry(key: "MeasureName", value: raw)
                guard kernels[section.name.lowercased()] == .string,
                      kernels[try value(entry, in: section).lowercased()] == .time else {
                    throw decline(section, entry, "missing measure binding")
                }
            }
        }
        return kernels
    }

    private final class FrozenSource: SourceProvider {
        let file: URL
        let text: String
        var unexpectedRequest = false
        init(file: URL, text: String) { self.file = file.standardizedFileURL; self.text = text }
        func sourceText(for url: URL) -> String? {
            guard url.standardizedFileURL == file else { unexpectedRequest = true; return "" }
            return text
        }
    }

    private final class EnvironmentHost: SkinHost {
        let value: SkinEnvironment
        var unexpectedMetricRead = false
        init(_ value: SkinEnvironment) { self.value = value }
        func environment(for skin: Skin) -> SkinEnvironment { value }
        func skinNeedsDisplay(_ skin: Skin) {}
        func skin(_ skin: Skin, handle bang: Bang) -> Bool { false }
        func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {}
        func skin(_ skin: Skin, execute target: String, arguments: [String]) {}
        func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {}
        func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
            unexpectedMetricRead = true
            return (0, 0) // A read makes conversion fail; static load in this profile never needs metrics.
        }
        func imageSize(atPath path: String) -> (width: Double, height: Double)? {
            unexpectedMetricRead = true
            return nil
        }
    }
}
