import Foundation

/// The Desk suites' timing budgets are for a Mac someone is working at. CI's runners (the Intel one especially) are several
/// times slower, so there a budget only tells finishing from running away.
let deskCIScale: Double = ProcessInfo.processInfo.environment["CI"] == "true" ? 10 : 1
import DesksetCore
import DeskLanguage

/// The Desk catalog (docs: the language specification §5, §6, §9.7): names unique per kind, documentation in both
/// languages, examples that hold up, Rainmeter mappings that name options the engine's schema knows, facets and the
/// editor's page fields, display names for every type, the diagnostics as data, units, and how fast the catalog
/// answers. Suites: "Desk: catalog …".
func runDeskCatalogTests(_ t: TestRunner) {
    let c = DeskCatalog.current

    t.suite("Desk: catalog names are unique per kind") {
        func unique<T>(_ items: [T], _ what: String, _ key: (T) -> String) {
            var seen = Set<String>()
            for item in items {
                let k = key(item)
                t.check(!k.isEmpty, "\(what): an empty name")
                t.check(seen.insert(k).inserted, "\(what): \(k) twice")
            }
        }
        unique(c.components, "component", \.name)
        unique(c.modifiers, "modifier", \.name)
        unique(c.facets, "facet") { $0.id.rawValue }
        unique(c.namespaces, "namespace", \.name)
        for ns in c.namespaces { unique(ns.members, "member of \(ns.name)") { "\($0.name)\($0.kind == .field ? "" : "()")" } }
        unique(c.functions, "function", \.name)
        unique(c.records, "record", \.id)
        for r in c.records { unique(r.fields, "field of \(r.id)") { "\($0.name)\($0.kind == .field ? "" : "()")" } }
        unique(c.typeMembers, "value type", \.type)
        for tm in c.typeMembers { unique(tm.members, "member of \(tm.type)") { "\($0.name)\($0.kind == .field ? "" : "()")" } }
        unique(c.enums, "enum", \.id)
        for e in c.enums { unique(e.cases, "case of \(e.id)", \.name) }
        unique(c.namedValues, "named value") { "\($0.type).\($0.name)" }
        unique(c.controls, "control", \.name)
        unique(c.infoFields, "info field", \.name)
        unique(c.packageFields, "package field", \.name)
        unique(c.units, "unit", \.spelling)
        unique(c.unitMisspellings, "unit spelling", \.spelling)
        unique(c.permissions, "permission", \.id)
        unique(c.features, "feature", \.id)
        unique(c.displayNames, "display name", \.id)
        unique(c.diagnostics, "diagnostic") { $0.id.rawValue }
        unique(c.fixItTitles, "fix-it title", \.key)
        unique(c.notes, "note", \.key)
        unique(c.compatDetails, "Rainmeter detail") { "\($0.owner) \($0.key)" }
        unique(c.rereadingCommands, "command") { "\($0.command) \($0.codeFlag ?? "")" }
        unique(c.foreign, "foreign row") { "\($0.pattern) \($0.context)" }

        // A misspelling is never a unit, and a label repeated among format options applies to other types.
        let unitSpellings = Set(c.units.map(\.spelling))
        for m in c.unitMisspellings { t.check(!unitSpellings.contains(m.spelling), "\(m.spelling) is a unit and a misspelling") }
        for (label, rows) in Dictionary(grouping: c.formatOptions, by: \.label) where rows.count > 1 {
            let applies = rows.flatMap(\.appliesTo)
            t.equal(Set(applies).count, applies.count, "\(label): rows apply to the same type")
        }
        // Qualified names (`Weekday.monday`, `Color.text`) never mean two things.
        let typeNames = c.enums.map(\.id) + ["Color", "Paint"]
        for name in typeNames {
            t.check(c.component(named: name) == nil, "\(name) is a component and a type")
            t.check(c.record(name) == nil, "\(name) is a record and a type")
        }
    }

    t.suite("Desk: catalog docs are complete in both languages") {
        let items = c.documentedItems()
        t.check(items.count > 400, "documented items: \(items.count)")
        for item in items {
            let d = item.doc
            let place = item.path.description
            t.check(!d.en.trimmingCharacters(in: .whitespaces).isEmpty, "\(place): no English")
            t.check(!d.zh.trimmingCharacters(in: .whitespaces).isEmpty, "\(place): no Chinese")
            t.check(!d.example.trimmingCharacters(in: .whitespaces).isEmpty, "\(place): no example")
            t.equal(d.since, AppVersion.deskFirstRelease, "\(place): since")
            t.check((0...100).contains(d.rank), "\(place): rank \(d.rank)")
            if let title = item.title { t.check(title.isComplete, "\(place): title in one language only") }
            if let minimum = d.minimumMacOS { t.check((14...26).contains(minimum), "\(place): macOS \(minimum)") }
            // Chinese text is Chinese: at least one CJK character unless it is a name (App, SF, GPU…).
            if d.zh.count > 6 {
                t.check(d.zh.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(place): zh \(d.zh)")
            }
        }
        for p in c.allParameters() {
            t.check(p.value.doc.isComplete, "\(p.place): parameter doc in one language only")
        }
        for f in c.facets { t.check(f.displayName.isComplete, "facet \(f.id): display name") }
        for x in c.permissions { t.check(x.needsPhrase.isComplete, "permission \(x.id): needs phrase") }
        for x in c.features { t.check(x.fallback.isComplete, "feature \(x.id): fallback") }
        for e in c.enums {
            for k in e.cases { t.check(k.title?.isComplete ?? false, "\(e.id).\(k.name): title") }
        }
    }

    t.suite("Desk: catalog keywords hold the Rainmeter spelling and people's guesses") {
        // Components, modifiers and data list the words people guess; at least one of their Rainmeter spellings is
        // among them (Percent for battery.level).
        var checked = 0
        for item in c.documentedItems() {
            switch item.path {
            case .component, .modifier, .member, .recordField: break
            default: continue
            }
            let keywords = Set(item.doc.keywords.map(DeskCatalog.normalizedKeyword))
            t.check(!keywords.isEmpty, "\(item.path): no keywords")
            let spellings = item.doc.rainmeter.flatMap(\.searchTerms).map(DeskCatalog.normalizedKeyword)
            if !spellings.isEmpty {
                t.check(spellings.contains { keywords.contains($0) },
                        "\(item.path): keywords \(item.doc.keywords) lack all of \(spellings)")
                checked += 1
            }
        }
        t.check(checked > 150, "items with Rainmeter spellings: \(checked)")
        // The guessing test's wrong guesses (§6.2 step 3) lead to the right name.
        let guesses: [(String, CatalogPath)] = [
            ("percent", .member(namespace: "battery", name: "level")),
            ("charge", .member(namespace: "battery", name: "level")),
            ("Percent", .member(namespace: "battery", name: "level")),
            ("temp", .recordField(record: "WeatherNow", name: "temperature")),
            ("load", .member(namespace: "cpu", name: "usage")),
            ("ProgressBar", .component("Progress")),
            ("progress-bar", .component("Progress")),
            ("Dropdown", .control("Picker")),
            ("fontSize", .modifier("font")),
            ("VStack", .component("Column")),
            ("blur", .namedValue(type: "Paint", name: "glass")),
        ]
        for (word, path) in guesses {
            t.check(c.index.keywordMatches(word).contains(path), "\(word) → \(path): \(c.index.keywordMatches(word))")
        }
    }

    t.suite("Desk: catalog examples hold up") {
        let checker = DeskExampleCheck(catalog: c)
        var count = 0
        for item in c.documentedItems() {
            let context = item.doc.exampleContext
            for problem in checker.problems(in: item.doc.example, alongside: context.declarations + context.siblings) {
                t.check(false, "\(item.path): \(problem) in \(item.doc.example)")
            }
            count += 1
        }
        t.check(count > 400, "examples: \(count)")
        // The checker itself catches what it is for.
        t.check(!checker.problems(in: #"Text("{cpu.usge}%")"#).isEmpty, "a wrong member")
        t.check(!checker.problems(in: #"Text("CPU").colour(.red)"#).isEmpty, "a wrong modifier")
        t.check(!checker.problems(in: #"Txt("CPU")"#).isEmpty, "a wrong component")
        t.check(!checker.problems(in: ".every(5m) { page = page + 1 }").isEmpty, "a wrong unit")
        t.check(!checker.problems(in: "if a && b { }").isEmpty, "a foreign operator")
        t.check(!checker.problems(in: #"Text("A"#).isEmpty, "unclosed text")
        t.check(!checker.problems(in: #"Row { Text("A") "#).isEmpty, "an unclosed block")
        t.check(!checker.problems(in: #"Text("{weather.now.temprature}")"#).isEmpty, "a wrong record field")
        t.check(!checker.problems(in: ".font(.cation)").isEmpty, "a wrong choice")
        t.check(!checker.problems(in: "Text(options.colour)").isEmpty, "a wrong option")
        t.equal(checker.problems(in: "for d in disks { Text(d.name) }"), [], "a loop variable takes its record")
        t.equal(checker.problems(in: #"Text("{weather.at(options.city).now.temperature}")"#), [])
        t.equal(checker.problems(in: ##"Text(web.text("https://example.com").match(#"<t>(.*)</t>"#).item(1))"##), [])
    }

    t.suite("Desk: catalog Rainmeter mappings name options Deskset knows") {
        // The inspector draws Position and Size itself, so X, Y, W and H are in no card; the inline text options are
        // edited in the text itself. Both are options every meter (String) reads.
        let drawnByInspector: Set<String> = ["x", "y", "w", "h"]
        let inlineOptions: Set<String> = ["inlinesetting", "inlinepattern"]
        let allMeterKeys = EditorSchema.meterTypes.reduce(into: Set<String>()) { $0.formUnion(EditorSchema.keys(EditorSchema.meterGroups($1))) }
        let measureNames = EditorSchema.measureTypes.map(\.name)
        let allMeasureKeys = measureNames.reduce(into: Set<String>()) { keys, name in
            let type = EditorSchema.measureTypes.first { $0.name == name }!
            keys.formUnion(EditorSchema.keys(type.isPlugin ? EditorSchema.measureGroups("Plugin", plugin: name)
                                                          : EditorSchema.measureGroups(name)))
        }
        let skinKeys = EditorSchema.keys(EditorSchema.skinGroups)
        let metadataKeys = EditorSchema.keys([EditorSchema.aboutGroup])
        // Built-in variables, and the mouse variables of mouse actions (`$MouseX$`, `$MouseX:%$`; Skin.swift).
        let variables = Set((BuiltInVariables.names + BuiltInVariables.macAppearanceNames
                             + ["MouseX", "MouseY", "MouseX:%", "MouseY:%"]).map { $0.lowercased() })

        func knows(_ key: String, in groups: [EditorSchema.Group], value: String?, _ place: String) {
            let k = key.lowercased()
            guard let property = EditorSchema.property(key, in: groups) else {
                t.check(drawnByInspector.contains(k) || inlineOptions.contains(k), "\(place): no option \(key)")
                return
            }
            // A value of a choice must be one of its choices (or an alias), unless other values are allowed.
            if let value, let choices = property.kind.choices, property.otherValues == .none {
                t.check(EditorSchema.choice(for: value, in: choices) != nil, "\(place): \(key)=\(value) is not a choice")
            }
        }

        let mappings = c.allRainmeterMappings()
        t.check(mappings.count > 300, "mappings: \(mappings.count)")
        for placed in mappings {
            let m = placed.value
            let place = placed.place
            switch m.owner {
            case .meter(let type):
                if type.isEmpty {
                    if let key = m.key {
                        let k = key.lowercased()
                        t.check(allMeterKeys.contains(k) || drawnByInspector.contains(k) || inlineOptions.contains(k),
                                "\(place): no meter option \(key)")
                    }
                } else {
                    t.check(EditorSchema.meterTypes.contains { $0.caseInsensitiveCompare(type) == .orderedSame },
                            "\(place): no meter type \(type)")
                    if let key = m.key { knows(key, in: EditorSchema.meterGroups(type), value: m.value, place) }
                }
            case .measure(let type, let plugin):
                if let plugin {
                    t.check(EditorSchema.measureType(type: "Plugin", plugin: plugin) != nil, "\(place): no plugin \(plugin)")
                    if let key = m.key, key != "Plugin" {
                        knows(key, in: EditorSchema.measureGroups("Plugin", plugin: plugin), value: m.value, place)
                    }
                } else if type.isEmpty {
                    if let key = m.key { t.check(allMeasureKeys.contains(key.lowercased()), "\(place): no measure option \(key)") }
                } else {
                    t.check(EditorSchema.measureType(type: type) != nil, "\(place): no measure type \(type)")
                    if let key = m.key { knows(key, in: EditorSchema.measureGroups(type), value: m.value, place) }
                }
            case .skin, .window, .contextMenu:
                if let key = m.key { t.check(skinKeys.contains(key.lowercased()), "\(place): no [Rainmeter] option \(key)") }
            case .metadata:
                if let key = m.key { t.check(metadataKeys.contains(key.lowercased()), "\(place): no [Metadata] key \(key)") }
            case .variables:
                if let key = m.key { t.check(variables.contains(key.lowercased()), "\(place): no built-in variable \(key)") }
            case .bang:
                if let key = m.key { t.check(BangCatalog.isKnown(key), "\(place): no bang \(key)") }
            }
        }
        // The Rainmeter details a converted widget may keep: each names what the renderer reads.
        var props = Set<String>()
        for d in c.compatDetails {
            t.check(!d.appliesTo.kinds.isEmpty, "detail \(d.key): applies to nothing")
            t.check(props.insert(d.prop).inserted && d.prop.hasPrefix("compat."), "detail \(d.key): prop \(d.prop)")
        }
        t.check(c.compatDetails.contains { $0.key == "AntiAlias" } && c.compatDetails.contains { $0.key == "AccurateText" },
                "AntiAlias and AccurateText are kept (§7.1)")
        t.check(!c.compatDetails.contains { $0.key == "BarBorder" }, "BarBorder is DK5027's example, not kept")
    }

    t.suite("Desk: catalog modifiers, facets and flags") {
        let facetIDs = Set(c.facets.map(\.id))
        var setBySomething = Set<FacetID>()
        var sortKeys = Set<Int>()
        for m in c.modifiers {
            t.check(m.sortKey > 0 && m.sortKey <= c.modifiers.count, ".\(m.name): sort key \(m.sortKey)")
            t.check(sortKeys.insert(m.sortKey).inserted, ".\(m.name): sort key \(m.sortKey) twice")
            t.check(m.title.isComplete, ".\(m.name): title")
            t.check(!m.signatures.isEmpty, ".\(m.name): no signature")
            if m.appliesTo.kinds.isEmpty { t.equal(m.context, .option, ".\(m.name) applies to nothing") }
            for f in m.facets + Array(m.fixedValues.keys) {
                t.check(facetIDs.contains(f), ".\(m.name): facet \(f) is not in the facet table")
                setBySomething.insert(f)
            }
            for s in m.signatures {
                for p in s.params {
                    for f in p.facets { t.check(m.facets.contains(f), ".\(m.name) \(p.name): facet \(f) not listed") }
                    // A modifier that sets facets says, for every value it takes, which ones.
                    if !m.facets.isEmpty && p.role != .condition {
                        t.check(!p.facets.isEmpty, ".\(m.name) \(p.name): sets no facet")
                    }
                }
            }
            let isEventOrTiming = m.event != nil || m.timing != nil
            if isEventOrTiming {
                t.equal(m.block, .actions(required: true), ".\(m.name): an action block")
            }
            // §4.8.4, §4.12, DK5009: what may carry `if:`, sit in a style or inside `.hover`.
            if isEventOrTiming || ["menu", "name", "hover", "pressed"].contains(m.name) {
                t.check(!m.acceptsCondition, ".\(m.name) takes no if:")
                t.check(!m.allowedInState, ".\(m.name) is not allowed inside .hover")
            }
            if isEventOrTiming || ["menu", "name", "position"].contains(m.name) {
                t.check(!m.allowedInStyle, ".\(m.name) is not allowed in a style")
            }
        }
        for e in c.enums { for k in e.cases { for f in k.facetValues.keys { t.check(facetIDs.contains(f), "\(e.id).\(k.name): facet \(f)") } } }
        for comp in c.components { for f in comp.defaults.keys { t.check(facetIDs.contains(f), "\(comp.name): default \(f)") } }
        for f in c.facets { t.check(setBySomething.contains(f.id), "facet \(f.id) is set by no modifier") }

        // Only four modifiers inherit (.font with .bold and .italic, .color, .digits, .align), §4.8.6.
        t.equal(Set(c.modifiers.filter(\.inheritable).map(\.name)), ["font", "bold", "italic", "color", "digits", "align"])
        t.equal(Set(c.facets.filter(\.inheritable).map(\.id.rawValue)),
                ["font.family", "font.size", "font.weight", "font.italic", "font.design", "color", "digits", "align"])
        // Repeatable: .style, .hidden, .rainmeter always; .onScroll once per direction (§4.8.3).
        for m in c.modifiers {
            switch m.name {
            case "style", "hidden", "rainmeter": t.equal(m.repeatable, .yes, ".\(m.name)")
            case "onScroll": t.equal(m.repeatable, .perArgument(0), ".\(m.name)")
            default: t.equal(m.repeatable, .no, ".\(m.name)")
            }
        }
        // The box (§4.8.1).
        let layers: [String: BoxLayer] = ["margin": .margin, "shadow": .shadow, "background": .background, "border": .border,
                                          "clip": .clip, "padding": .padding, "offset": .transform, "rotate": .transform,
                                          "scale": .transform]
        for (name, layer) in layers { t.equal(c.modifier(named: name)?.boxLayer, layer, ".\(name)") }
        // Soft presets: `.font(.headline)` sets family, size, weight and design softly.
        t.check(c.modifier(named: "font")?.softFacets == true, ".font's presets are soft")
        let headline = c.enumeration("FontPreset")?.enumCase(named: "headline")
        t.equal(headline?.facetValues["font.size"], FacetValue("15"), ".headline is 15 pt")
        t.equal(headline?.facetValues["font.weight"], FacetValue(".semibold"))
        t.equal(c.enumeration("FontPreset")?.enumCase(named: "largeNumber")?.facetValues["digits"], FacetValue(".equalWidth"))
        // Inside one call a side beats an axis beats all (§4.8.3 rule 4).
        let padding = c.modifier(named: "padding")!.signatures[0]
        t.equal(padding.param(labelled: "top")?.specificity, 2)
        t.equal(padding.param(labelled: "horizontal")?.specificity, 1)
        t.equal(padding.params.first?.specificity, 0)
        t.equal(c.modifier(named: "bold")?.fixedValues["font.weight"], ".bold")
    }

    t.suite("Desk: catalog signatures and types") {
        let enumIDs = Set(c.enums.map(\.id))
        let recordIDs = Set(c.records.map(\.id))
        for placed in c.allTypes() {
            switch placed.value {
            case .enumeration(let id): t.check(enumIDs.contains(id), "\(placed.place): no enum \(id)")
            case .record(let id): t.check(recordIDs.contains(id), "\(placed.place): no record \(id)")
            default: break
            }
        }
        // Optional positional parameters of one signature take their values by type, so their types never overlap
        // (§4.3, D117): `.font(20, .rounded)` sets only the design.
        for placed in c.allSignatures() {
            let optional = placed.value.params.filter(\.isOptionalPositional)
            for (i, a) in optional.enumerated() {
                for b in optional.dropFirst(i + 1) {
                    t.check(!typesOverlap(a.type, b.type), "\(placed.place): \(a.name) and \(b.name) overlap")
                }
            }
            // Positional parameters come before labelled ones.
            if let firstLabel = placed.value.params.firstIndex(where: { $0.label != nil }) {
                t.check(placed.value.params[firstLabel...].allSatisfy { $0.label != nil }, "\(placed.place): a positional after a label")
            }
            var labels = Set<String>()
            for p in placed.value.params {
                if let label = p.label { t.check(labels.insert(label).inserted, "\(placed.place): \(label): twice") }
                if case .parameter(let other)? = p.defaultValue {
                    t.check(placed.value.param(named: other) != nil, "\(placed.place): default from \(other)")
                }
                if let tied = p.sameAs { t.check(placed.value.param(named: tied) != nil, "\(placed.place): tied to \(tied)") }
                if p.required { t.check(p.defaultValue == nil, "\(placed.place): \(p.name) is required and has a default") }
            }
            if case .sameAs(let param)? = placed.value.result {
                t.check(placed.value.param(named: param) != nil, "\(placed.place): result from \(param)")
            }
        }
        // Every value DK4002 inserts is Desk text: a required parameter has a preview value (§6.1).
        for p in c.allParameters() where p.value.required {
            t.check(p.value.previewValue != nil, "\(p.place): required, with no preview value")
        }
        // The `.padding()` rule (D133): a modifier whose parameters are all optional with no default has a preview.
        for m in c.modifiers {
            for s in m.signatures where m.fixedValues.isEmpty && !s.params.isEmpty
                && s.params.allSatisfy({ !$0.required && $0.defaultValue == nil }) {
                t.check(s.params.contains { $0.previewValue != nil }, ".\(m.name): nothing to insert for .\(m.name)()")
            }
        }
    }

    t.suite("Desk: catalog data, records and actions") {
        let permissionIDs = Set(c.permissions.map(\.id))
        t.equal(permissionIDs, Set(c.enumeration("Permission")?.cases.map(\.name) ?? []), "permissions = the Permission enum")
        t.equal(Set(c.features.map(\.id)), Set(c.enumeration("Feature")?.cases.map(\.name) ?? []), "features = the Feature enum")
        var settable: [String] = []
        var userOnly: [String] = []
        for ns in c.namespaces {
            t.check(ns.title.isComplete, "\(ns.name): title")
            if let p = ns.permission { t.check(permissionIDs.contains(p), "\(ns.name): permission \(p)") }
            if let main = ns.mainMember { t.check(ns.member(named: main) != nil, "\(ns.name): main member \(main)") }
            if let record = ns.instanceOf { t.check(c.record(record) != nil, "\(ns.name): instance of \(record)") }
            for m in ns.members {
                let path = "\(ns.name).\(m.name)"
                if let p = m.permission { t.check(permissionIDs.contains(p), "\(path): permission \(p)") }
                if m.settable { settable.append(path) }
                if m.userInitiatedOnly { userOnly.append(path) }
                if m.kind != .field { t.check(!m.signatures.isEmpty, "\(path): no signature") }
                if case .bytes = m.type { t.check(m.displayBase != nil, "\(path): bytes without a display base") }
                if let twin = m.settableTwin {
                    let twinPath = twin.hasSuffix("()") ? String(twin.dropLast(2)) : twin
                    t.check(c.member(path: twinPath) != nil, "\(path): twin \(twin)")
                }
            }
        }
        for f in c.functions {
            if let p = f.permission { t.check(permissionIDs.contains(p), "\(f.name): permission \(p)") }
            if f.userInitiatedOnly { userOnly.append(f.name) }
            if let twin = f.actionTwin { t.check(c.function(named: twin)?.kind == .action, "\(f.name): twin \(twin)") }
        }
        // D39 and D34 (revised as D106).
        t.equal(Set(settable), ["volume.level", "volume.muted", "music.position"])
        t.equal(Set(userOnly), ["open", "copy", "run", "trash.empty"])
        for p in c.permissions {
            for needed in p.neededBy {
                let base = needed.hasSuffix(".*") ? String(needed.dropLast(2)) : needed
                t.check(c.namespace(named: base) != nil || c.member(path: base) != nil || c.function(named: base) != nil
                        || base == "apps.frontmost.windowTitle", "permission \(p.id): \(needed)")
            }
        }
        // The records of §5.10, field by field.
        let recordFields: [String: String] = [
            "MonthGrid": "title year month weekdays days",
            "DayCell": "number date inMonth isToday isWeekend weekday lunar",
            "CalendarEvent": "id title calendar location start end allDay color",
            "CPUCore": "number usage", "Disk": "name path free used total usage removable",
            "NetworkInterface": "name download upload total downloaded uploaded",
            "App": "name bundleId fullScreen windowTitle",
            "WeatherNow": "temperature feelsLike dewPoint condition conditionCode symbol isDaylight humidity cloudCover fog "
                + "chanceOfRain chanceOfThunder pressure uvIndex wind gust windDirection windFrom beaufort precipitation "
                + "temperatureColor",
            "HourForecast": "time temperature dewPoint condition conditionCode symbol isDaylight humidity cloudCover fog "
                + "chanceOfRain chanceOfThunder pressure uvIndex wind gust windDirection windFrom beaufort precipitation "
                + "temperatureColor",
            "DayForecast": "date high low condition conditionCode symbol uvIndex wind gust beaufort precipitation chanceOfRain "
                + "chanceOfThunder temperatureColor sunrise sunset solarNoon dayLength",
            "Fan": "speed minimum maximum target", "Feed": "title items", "FeedItem": "title link summary date image",
            "FileItem": "name path kind size modified isFolder icon", "FolderInfo": "size fileCount folderCount",
            "CommandResult": "output lines number json exitCode running error", "Size": "width height preset",
            "Event": "x y dx dy xPercent yPercent direction files text",
        ]
        for (record, fields) in recordFields {
            t.equal(Set(c.record(record)?.fields.map(\.name) ?? []), Set(fields.split(separator: " ").map(String.init)), record)
        }
        // `weather` and `weather.at(…)` are both a Weather; `sun`, `sun.at(…)` and `sun.day(…)` a Sun.
        for (namespace, record, functions) in [("weather", "Weather", ["at"]), ("sun", "Sun", ["at", "day"])] {
            let members = Set(c.namespace(named: namespace)?.members.map(\.name) ?? []).subtracting(functions)
            t.equal(Set(c.record(record)?.fields.map(\.name) ?? []), members, "\(record) has the members of \(namespace)")
            t.check(c.record(record)?.fields.allSatisfy { $0.permission == nil } ?? false, "\(record)'s fields need no permission")
        }
        // Identity fields for `for` (§4.15).
        let identities = ["DayCell": "date", "CalendarEvent": "id", "FileItem": "path", "FeedItem": "link",
                          "HourForecast": "time", "DayForecast": "date"]
        for (record, field) in identities { t.equal(c.record(record)?.identityField, field, "\(record)'s identity") }
        for r in c.records {
            if let id = r.identityField { t.check(r.field(named: id) != nil, "\(r.id): identity \(id) is no field") }
        }
        // Member lookup by type (§4.2), projection included.
        t.equal(c.member("temperature", of: .record("WeatherNow"), call: false)?.type, .temperature)
        t.equal(c.member("temperature", of: .list(.record("HourForecast")), call: false)?.type, .list(.temperature),
                "projection: weather.hourly.temperature")
        t.equal(c.member("count", of: .list(.string), call: false)?.type, .plainNumber)
        t.check(c.member("ifMissing", of: .percent, call: true) != nil, "every value has .ifMissing")
        t.check(c.member("count", of: .json, call: false) == nil, "on Json a member without parentheses is a field")
        t.check(c.member("count", of: .json, call: true) != nil, ".count() on Json")
        t.equal(c.member(path: "memory.used")?.displayBase, 1024)
        t.equal(c.member(path: "disk.free")?.displayBase, 1000)
        t.equal(c.member(path: "cpu.usage")?.range, .fixed(0...100))
        t.equal(c.member(path: "memory.used")?.range, .member("total"))
        t.equal(c.member(path: "network.download")?.range, .observed)
        t.equal(c.namespace(named: "cpu")?.mainMember, "usage")
        t.equal(c.namespace(named: "time")?.mainMember, "now")
        t.equal(c.namespace(named: "weather")?.permission, "location")
        t.equal(c.member(path: "weather.at")?.permission, nil, "weather.at needs no permission")
    }

    t.suite("Desk: catalog Mac marks and default formats") {
        // 🍎 in the listings of §5.4–§5.8: Mac-specific items, no Rainmeter counterpart or a Deskset extension.
        func macOnly(_ items: [DocumentedItem]) -> Set<String> {
            Set(items.filter(\.doc.macOnly).map(\.path.description))
        }
        let items = c.documentedItems()
        t.equal(macOnly(items.filter { if case .component = $0.path { return true } else { return false } }),
                ["Label", "Icon", "Button", "Toggle", "Slider", "Input"])
        t.equal(macOnly(items.filter { if case .modifier = $0.path { return true } else { return false } }),
                [".background", ".iconColors", ".iconEffect", ".onDrop", ".onSubmit"])
        t.equal(macOnly(items.filter { if case .control = $0.path { return true } else { return false } }), ["Secret", "FolderPicker"])
        t.equal(macOnly(items.filter { if case .function = $0.path { return true } else { return false } }), ["notify"])
        let macData = macOnly(items.filter { if case .member = $0.path { return true } else { return false } })
        let expectedOutsidePlaces: Set<String> = ["calendar.events", "memory.pressure", "battery.health", "battery.cycles",
                                                  "system.dark", "system.accentColor", "system.model", "apps.frontmost"]
        t.equal(macData.filter { !["weather.", "sun.", "moon.", "sensors."].contains(where: $0.hasPrefix) }, expectedOutsidePlaces)
        for ns in ["weather", "sun", "moon", "sensors"] {
            for m in c.namespace(named: ns)?.members ?? [] { t.check(macData.contains("\(ns).\(m.name)"), "\(ns).\(m.name) is 🍎") }
        }
        // Every dimension has its default format (§4.11), and so do the other displayable types.
        let formatted = Set(c.typeFormats.map(\.type))
        for d in Dimension.allCases { t.check(formatted.contains(.number(d)), "no default format for \(d)") }
        for type in [DeskType.bool, .string, .date, .json] { t.check(formatted.contains(type), "no default format for \(type)") }
        for f in c.typeFormats {
            t.check(f.rule.isComplete && !f.examples.isEmpty, "\(f.type): rule and examples")
        }
        t.equal(c.typeFormats.first { $0.type == .percent }?.decimals, 0, "a percentage is a whole number")
        t.equal(c.member(path: "uptime")?.defaultFormat, nil)
        t.equal(c.namespace(named: "uptime")?.value?.defaultFormat, .style(".full"))
        t.equal(c.member(path: "music.position")?.defaultFormat, .style(".clock"))
        t.equal(c.member(path: "time.now")?.defaultFormat, .style(".time"))
    }

    t.suite("Desk: catalog holds every name of the listings") {
        // The listings of §5.3–§5.11, name by name: a name missing from the catalog fails; a name the listings do not
        // have is printed, so additions are deliberate.
        var extras: [String] = []
        func holds(_ what: String, _ actual: [String], _ listed: String) {
            let expected = listed.split(separator: " ").map(String.init)
            for name in expected where !actual.contains(name) { t.check(false, "\(what): \(name) is missing") }
            extras += actual.filter { !expected.contains($0) }.map { "\(what) \($0)" }
        }
        holds("component", c.components.map(\.name), "Column Row Grid Freeform Scroll Spacer Divider Text Label Icon Image Progress "
              + "Gauge Graph Rectangle Circle Ellipse Capsule Line Arc Path Button Toggle Slider Input Item Menu")
        holds("control", c.controls.map(\.name),
              "Picker Toggle Slider Stepper Input Secret ColorPicker FontPicker ImagePicker FolderPicker DatePicker Section Choice")
        holds("info field", c.infoFields.map(\.name), "name description author version license homepage source category size "
              + "refresh permissions network level clickThrough draggable deskVersion requires convertedFrom")
        holds("package field", c.packageFields.map(\.name), "name description author version license homepage deskVersion requires")
        holds("function", c.functions.map(\.name), "round floor ceil abs min max clamp sqrt random rgb color gradient radialGradient "
              + "supports open copy notify show hide showOrHide log run after files folder command")
        let members: [String: String] = [
            "time": "now", "calendar": "month events", "cpu": "usage core cores coreCount",
            "memory": "used free total usage pressure", "swap": "used total usage",
            "disk": "free used total usage name path removable at",
            "network": "download upload total downloaded uploaded online address interface",
            "battery": "level charging pluggedIn timeRemaining present health cycles",
            "system": "name userName dark accentColor osVersion model idleTime", "wifi": "name signal connected",
            "apps": "frontmost running",
            "music": "title artist album cover playing position duration progress player shuffle repeat play pause playPause "
                + "next previous openPlayer seek",
            "volume": "level muted device set mute unmute toggleMute", "audio": "bands level peak left right",
            "audio.microphone": "bands level peak left right",
            "weather": "now today hourly daily place placeDetail country countryCode latitude longitude timeZone status "
                + "statusText statusSymbol updated forecastMade credit creditShort creditLink licenseLink at refresh",
            "sun": "sunrise sunset solarNoon dawn dusk nauticalDawn nauticalDusk astronomicalDawn astronomicalDusk "
                + "goldenHourMorningEnd goldenHourEveningStart dayLength daylightProgress elevation azimuth isUp state at day",
            "moon": "phase illumination phaseName symbol",
            "sensors": "cpuTemperature cpuPerformanceTemperature cpuEfficiencyTemperature gpuTemperature socTemperature "
                + "batteryTemperature ssdTemperature fanSpeed fan power adapterPower cpuPower gpuPower neuralEnginePower "
                + "memoryPower cpuClock gpuClock gpuUsage gpuMemory cpuVoltage read",
            "web": "json text feed image", "trash": "count size open empty", "widget": "size reload openOptions edit",
            "math": "sin cos tan asin acos atan atan2 exp ln log10 power sign frac trunc pi e bitAnd bitOr bitXor bitNot",
        ]
        for (namespace, names) in members { holds(namespace, c.namespace(named: namespace)?.members.map(\.name) ?? [], names) }
        for value in ["disks", "uptime"] { t.check(c.namespace(named: value)?.valueType != nil, "\(value) is a value") }
        t.check(c.namespace(named: "options")?.dynamicMembers == true, "options has the file's own members")
        let enumCases: [String: String] = [
            "Alignment": "topLeft top topRight left center right bottomLeft bottom bottomRight", "HAlign": "left center right",
            "VAlign": "top center bottom baseline", "Axis": "vertical horizontal", "Direction": "right left up down",
            "ScrollDirection": "up down left right", "LengthKeyword": "fit fill", "SizePreset": "small medium large fit",
            "Category": "time system media weather productivity developer other", "WindowLevel": "desktop normal onTop",
            "Permission": "music location calendar microphone systemAudio commands notifications files accessibility",
            "Weekday": "sunday monday tuesday wednesday thursday friday saturday",
            "FontPreset": "largeTitle title headline body callout caption footnote largeNumber number",
            "Weight": "ultralight thin light regular medium semibold bold heavy black", "FontDesign": "standard rounded mono serif",
            "Digits": "equalWidth normal", "RadiusKeyword": "full", "ImageMode": "fit fill stretch tile",
            "Flip": "horizontal vertical both", "IconColors": "monochrome hierarchical multicolor",
            "IconEffect": "pulse bounce breathe wiggle rotate", "GaugeShape": "ring arc pie needle",
            "GraphShape": "line area bars", "Animation": "smooth spring linear", "Transition": "fade scale slide",
            "Cursor": "arrow hand text crosshair notAllowed resizeUpDown resizeLeftRight",
            "MemoryPressure": "normal warning critical",
            "WeatherStatus": "ready loading stale noLocation placeNotFound locationDenied locationUnavailable notCovered "
                + "refused rateLimited offline turnedOff preview tooManyPlaces",
            "SunState": "normal midnightSun polarNight", "FileSort": "name size date kind",
            "Feature": "liquidGlass symbolEffects sensors", "ByteUnit": "auto bytes kb mb gb tb kib mib gib tib",
            "TemperatureUnit": "auto celsius fahrenheit kelvin", "FrequencyUnit": "auto mhz ghz", "UnitStyle": "none short full",
            "DurationStyle": "full short clock",
            "DatePreset": "time date dateTime weekday shortWeekday month shortMonth year relative",
        ]
        for (id, cases) in enumCases { holds("enum \(id)", c.enumeration(id)?.cases.map(\.name) ?? [], cases) }
        holds("enum", c.enums.map(\.id), enumCases.keys.sorted().joined(separator: " "))
        holds("unit", c.units.map(\.spelling), "pt ms s min h d % deg ° rad °C °F B KB MB GB TB KiB MiB GiB TiB B/s KB/s MB/s "
              + "GB/s KiB/s MiB/s GiB/s Hz kHz MHz GHz W mW V mV A mA rpm km/h mph m/s kn mm inch hPa mbar inHg")
        holds("format option", Array(Set(c.formatOptions.map(\.label))), "decimals unit unitStyle bits format style missing")
        // The editor's insertion order (§5.6, `sortKey`).
        let order = "style font bold italic color align uppercase lowercase titleCase lines digits outline underline "
            + "strikethrough letterSpacing lineSpacing imageMode tint grayscale flip keepEdges crop iconColors iconEffect fill "
            + "stroke track width height size padding position offset margin background rounded border shadow opacity blur clip "
            + "rotate scale hover pressed animate appear hidden tooltip cursor onClick onDoubleClick onRightClick onMouseEnter "
            + "onMouseLeave onScroll onDrag onDrop onSubmit menu every when onChange onLoad onWake name voiceOver rainmeter"
        let sorted = c.modifiers.sorted { $0.sortKey < $1.sortKey }.map(\.name).filter { $0 != "help" }
        t.equal(sorted, order.split(separator: " ").map(String.init), "sort keys follow §5.6")
        for extra in extras { print("  note    not in the listings: \(extra)") }
    }

    t.suite("Desk: catalog sensor keys match the engine's") {
        // `sensors.read(key)` is typed by the key's kind (§5.7); the kinds are the engine's (SensorKeys).
        func type(of kind: SensorKind) -> DeskType {
            switch kind {
            case .temperature: return .temperature
            case .fan: return .rpm
            case .power: return .power
            case .frequency: return .frequency
            case .percent: return .percent
            case .count: return .plainNumber
            case .voltage: return .voltage
            case .current: return .current
            case .bytes: return .bytes
            }
        }
        for spec in c.sensorKeys {
            let sample = spec.pattern.replacingOccurrences(of: "N", with: "3")
            guard let kind = SensorKeys.kind(of: sample) else { t.check(false, "\(spec.pattern): no engine key"); continue }
            t.equal(spec.type, type(of: kind), spec.pattern)
            t.check(spec.label.isComplete, "\(spec.pattern): label")
            t.equal(c.sensorKey(sample)?.spec, spec, "\(sample) finds its row")
        }
        for (key, _) in SensorKeys.common {
            t.check(c.sensorKey(key) != nil, "the engine's \(key) is in the catalog")
        }
        t.equal(c.sensorKeyAliases, SensorKeys.aliases, "the same other spellings")
        t.equal(c.sensorKey("CPU.Temperature")?.key, "cpu")
        t.equal(c.sensorKey("cpu.core.12")?.spec.type, .temperature)
        t.check(c.sensorKey("cpu.core.0") == nil, "cores count from 1")
        t.check(c.sensorKey("fan.1.speed") == nil, "no such key")
        // The named members read the keys they say.
        for m in c.namespace(named: "sensors")?.members ?? [] where m.kind == .field {
            guard case .measure(_, let options, _) = m.lowering, case .literal(let key)? = options["Sensor"] else { continue }
            t.equal(c.sensorKey(key)?.spec.type, m.type, "sensors.\(m.name) reads \(key)")
        }
    }

    t.suite("Desk: catalog enums and implicit members") {
        t.equal(Set(c.implicitMemberTypes("left")), ["HAlign", "Alignment", "Direction", "ScrollDirection"], "§4.13 rule 3")
        t.equal(c.implicitMemberTypes("sunday"), ["Weekday"])
        t.equal(c.implicitMemberTypes("glass"), ["Paint"])
        t.equal(c.implicitMemberTypes("red"), ["Color"])
        t.equal(c.implicitMemberTypes("caption"), ["FontPreset"])
        t.equal(c.implicitMemberTypes("nothing"), [])
        let presets = c.enumeration("SizePreset")?.cases.map(\.name) ?? []
        t.equal(presets, ["small", "medium", "large", "fit"])
        // The limits of §8.3 and §8.4.
        let l = c.limits
        t.equal([l.maximumFileBytes, l.maximumTokens, l.maximumBlockNesting, l.maximumExpressionNesting,
                 l.maximumDiagnosticsPerFile, l.maximumTextLength, l.maximumListLiteral, l.maximumRange, l.maximumForInstances,
                 l.maximumForNesting, l.maximumElementInstances, l.maximumOptions, l.maximumPendingAfters, l.maximumReactionRounds,
                 l.maximumSavedValueBytes, l.maximumSavedBytesPerInstance, l.maximumWebResponseBytes, l.maximumWebImageBytes,
                 l.maximumWebImageSide, l.notificationsPerMinute, l.maximumPackageBytes, l.maximumPackageFiles,
                 l.turnsOverBudgetBeforePause, l.deskVersion],
                [1_048_576, 200_000, 64, 128, 500, 32_768, 1_000, 1_000, 1_000, 4, 5_000, 100, 256, 16, 65_536, 1_048_576,
                 5_242_880, 20_971_520, 8_192, 1, 104_857_600, 2_000, 3, 1])
        t.equal([l.minimumEvery, l.everyTipBelow, l.minimumWebEvery, l.minimumCommandEvery, l.maximumCommandTimeout,
                 l.maximumUserActionDelay, l.evaluationBudgetPerTurn], [0.016, 0.25, 60, 1, 60, 2, 0.010])
        t.equal(l.refreshRange, 0.25...3_600)
        t.equal(l.afterRange, 0...86_400)
        t.equal(c.newestSince, AppVersion.deskFirstRelease, "the first catalog is all 1.0")
        t.equal(c.limits.smallSize, IdealSize(width: 170, height: 170))
        t.equal(c.limits.mediumSize, IdealSize(width: 356, height: 170))
        t.equal(c.limits.largeSize, IdealSize(width: 356, height: 356))
        let sizes = ["largeTitle": "26", "title": "20", "headline": "15", "body": "13", "callout": "12", "caption": "11",
                     "footnote": "10", "largeNumber": "34", "number": "22"]
        for (preset, size) in sizes {
            t.equal(c.enumeration("FontPreset")?.enumCase(named: preset)?.facetValues["font.size"]?.value, size, "D53 \(preset)")
        }
        let colors = ["accent", "text", "dim", "faint", "separator", "red", "orange", "yellow", "green", "mint", "teal", "cyan",
                      "blue", "indigo", "purple", "pink", "brown", "gray", "white", "black", "clear"]
        t.equal(c.namedValues.filter { $0.type == "Color" }.map(\.name), colors, "§5.11 colors")
        t.equal(c.namedValues.filter { $0.type == "Paint" }.map(\.name), ["glass", "clearGlass"])
        for e in c.enums { t.check(!e.cases.isEmpty, "\(e.id): no cases") }
    }

    t.suite("Desk: catalog page fields for the editor") {
        // What the editor's generated pages read: section, labels in both languages, control, presets, level, units and
        // range, long sample.
        for f in c.facets {
            let page = f.page
            t.check(page.label.isComplete, "facet \(f.id): page label")
            t.check(page.presets.allSatisfy { $0.label.isComplete }, "facet \(f.id): preset labels")
            if page.control == .segmented {
                t.check((2...4).contains(page.presets.count), "facet \(f.id): segmented with \(page.presets.count) presets")
            }
            if case .number(let d) = f.valueType, d != .plain, d != .time {
                t.check(f.unit != nil, "facet \(f.id): no unit")
            }
            if page.control == .slider { t.check(f.valueType == .fraction, "facet \(f.id): sliders are for opacity only") }
        }
        for comp in c.components {
            for s in comp.signatures {
                for p in s.params {
                    guard let page = p.page else { t.check(false, "\(comp.name) \(p.name): no page row"); continue }
                    t.check(page.label.isComplete, "\(comp.name) \(p.name): page label")
                    if page.control == .segmented {
                        t.check((2...4).contains(page.presets.count), "\(comp.name) \(p.name): segmented presets")
                    }
                }
            }
        }
        // Text people read has a long sample, for previews and the fit check.
        for id in ["tooltip", "voiceOver", "help", "name"] { t.check(c.facet(FacetID(id))?.page.longSample != nil, "facet \(id)") }
        t.check(c.component(named: "Text")?.signatures[0].params[0].page?.longSample != nil, "Text's content")
        // Every card has its essentials.
        for card in InspectorCard.allCases where card != .content && card != .interaction {
            t.check(c.facets.contains { $0.page.section == card && $0.page.level == .essential }, "card \(card): no essentials")
        }
    }

    t.suite("Desk: catalog display names") {
        func row(_ id: String) -> DisplayNameSpec? { c.displayName(id) }
        for d in Dimension.allCases {
            t.check(row("dimension:\(d.rawValue)")?.plural != nil, "dimension \(d)")
        }
        for placed in c.allTypes() {
            let id = placed.value.displayNameID
            t.check(row(id) != nil, "\(placed.place): no display name \(id)")
        }
        for e in c.enums { t.check(row("enum:\(e.id)")?.plural != nil, "enum \(e.id)") }
        for r in c.records { t.check(row("record:\(r.id)")?.plural != nil, "record \(r.id)") }
        for f in c.facets { t.check(row("facet:\(f.id)") != nil, "facet \(f.id)") }
        for x in c.components { t.check(row("component:\(x.name)") != nil, "component \(x.name)") }
        for p in c.enumeration("SizePreset")?.cases ?? [] { t.check(row("preset:\(p.name)") != nil, "preset \(p.name)") }
        for slot in ["expression", "modifier", "label", "closingBrace"] { t.check(row("slot:\(slot)") != nil, "slot \(slot)") }
        for spec in c.displayNames {
            t.check(spec.name.isComplete, "\(spec.id): one language only")
            if let plural = spec.plural { t.check(plural.isComplete, "\(spec.id): plural") }
            let placeholders = DiagnosticSpec.placeholderNames(in: spec.name.en) + DiagnosticSpec.placeholderNames(in: spec.name.zh)
            t.check(placeholders.allSatisfy { ["element", "name"].contains($0) }, "\(spec.id): placeholders \(placeholders)")
            // A display name starts with a small letter: templates capitalize it where it starts a sentence.
            if let first = spec.name.en.first, first.isLetter { t.check(first.isLowercase, "\(spec.id): \(spec.name.en)") }
        }
        // Rendering (§6.1): display names in each language, lists, a capital letter where a sentence starts.
        t.equal(c.displayText("type:bool", in: .simplifiedChinese), "是或否（`true` 或 `false`）")
        t.equal(c.displayText("type:nothing", in: .english), "a value", "an unknown id never shows")
        t.equal(c.displayText("record:DayCell", in: .english, plural: true), "days of a month")
        t.equal(DeskCatalog.joinedList(["a", "b", "c"], in: .english, or: true), "a, b or c")
        t.equal(DeskCatalog.joinedList(["a", "b", "c"], in: .simplifiedChinese, or: false), "a、b 和 c")
        t.equal(DeskCatalog.joinedList(["a"], in: .english, or: true), "a")
        t.equal(DeskCatalog.joinedList((1...10).map(String.init), in: .english, or: true), "1, 2, 3, 4, 5, 6, 7, 8, …")
        let mismatch = c.diagnostic(.typeMismatch)!
        let values = ["what": c.displayText("facet:font.size", in: .english), "expected": c.displayText(for: .length, in: .english),
                      "actual": c.displayText(for: .bool, in: .english), "hint": ""]
        t.equal(mismatch.message(.english, values).trimmingCharacters(in: .whitespaces),
                "The text size needs a length in points, such as `12`, but this is yes or no (`true` or `false`).")
        let zhValues = ["what": c.displayText("facet:font.size", in: .simplifiedChinese),
                        "expected": c.displayText(for: .length, in: .simplifiedChinese),
                        "actual": c.displayText(for: .bool, in: .simplifiedChinese), "hint": ""]
        t.equal(mismatch.message(.simplifiedChinese, zhValues), "字号要填长度（单位是点），比如 `12`，但这里填了是或否（`true` 或 `false`）。")
        // §5.15's rows, as written.
        t.equal(row("type:bool")?.name, LocalizedText("yes or no (`true` or `false`)", "是或否（`true` 或 `false`）"))
        t.equal(row("component:Progress")?.name, LocalizedText("the progress bar", "进度条"))
        t.equal(row("facet:padding.top")?.name, LocalizedText("the space at the top", "上边的内边距"))
        t.equal(row("preset:small")?.name, LocalizedText("the small size", "小号"))
        t.equal(c.displayName(for: .list(.record("DayCell"))), LocalizedText("a list of days of a month", "一组月历里的日子"))
        t.equal(c.displayName(for: .oneOf([.length, .enumeration("FontPreset")])).en,
                "a length in points, such as `12` or a text style, such as `.caption`")
    }

    t.suite("Desk: catalog diagnostics as data") {
        let byID = Dictionary(grouping: c.diagnostics, by: \.id)
        for id in DiagnosticID.allCases { t.equal(byID[id]?.count, 1, "\(id.rawValue) \(id.symbolicName)") }
        t.equal(c.diagnostics.map(\.id), DiagnosticID.allCases.sorted { $0.number < $1.number }, "in id order")
        let titleKeys = Set(c.fixItTitles.map(\.key))
        for d in c.diagnostics {
            let name = "\(d.id.rawValue) \(d.id.symbolicName)"
            t.check(d.template.isComplete, "\(name): template in one language only")
            t.check(!d.trigger.isEmpty, "\(name): no trigger")
            let en = Set(DiagnosticSpec.placeholderNames(in: d.template.en))
            let zh = Set(DiagnosticSpec.placeholderNames(in: d.template.zh))
            t.equal(en, zh, "\(name): the languages use other placeholders")
            var used = en
            for h in d.hints {
                t.check(h.text.isComplete, "\(name) hint \(h.key)")
                t.equal(d.placeholders[h.placeholder], .text, "\(name) hint \(h.key) fills {\(h.placeholder)}")
                let hinted = Set(DiagnosticSpec.placeholderNames(in: h.text.en))
                t.equal(hinted, Set(DiagnosticSpec.placeholderNames(in: h.text.zh)), "\(name) hint \(h.key): placeholders")
                used.formUnion(hinted)
            }
            t.equal(Set(d.placeholders.keys), used, "\(name): declared and used placeholders")
            for f in d.fixIts {
                t.check(titleKeys.contains(f.titleKey), "\(name): fix-it title \(f.titleKey)")
                if let offered = f.offeredWhen { t.check(offered.isComplete, "\(name): offered-when") }
            }
            // A rendered message leaves no placeholder behind.
            let values = Dictionary(uniqueKeysWithValues: used.map { ($0, "x") })
            for language in DiagnosticLanguage.allCases {
                let text = d.render(language, values)
                t.check(DiagnosticSpec.placeholderNames(in: text).isEmpty, "\(name): \(text)")
            }
            if let escalation = d.escalation { t.check(escalation.when.isComplete, "\(name): escalation") }
        }
        for title in c.fixItTitles { t.check(title.title.isComplete, "fix-it \(title.key)") }
        for note in c.notes { t.check(note.text.isComplete, "note \(note.key)") }
        // Severities as §6.3 and §6.4 list them; every other id is an error.
        let warnings: Set<String> = ["DK1004", "DK1005", "DK1013", "DK1019", "DK2021", "DK2024", "DK2033", "DK3020", "DK3021",
                                     "DK3022", "DK3036", "DK4013", "DK4022", "DK4031", "DK4032", "DK4042", "DK4050", "DK5005", "DK5012",
                                     "DK5014", "DK5018", "DK5020", "DK5021", "DK5024", "DK5025", "DK5027", "DK6008", "DK6009",
                                     "DK6011", "DK6012", "DK6101", "DK7013", "DK8102", "DK8104", "DK8105", "DK8303", "DK8401",
                                     "DK8403", "DK8502", "DK8603", "DK8604", "DK8605", "DK9011", "DK9013", "DK9014", "DK9310"]
        let infos: Set<String> = ["DK2030", "DK3026", "DK3027", "DK3029", "DK3032", "DK4033", "DK4038", "DK4043", "DK4044",
                                  "DK4046", "DK5013", "DK5026", "DK7008", "DK8003", "DK8406", "DK8609"]
        for d in c.diagnostics {
            let expected: Severity = warnings.contains(d.id.rawValue) ? .warning : infos.contains(d.id.rawValue) ? .info : .error
            t.equal(d.severity, expected, "\(d.id.rawValue) \(d.id.symbolicName)")
        }
        t.equal(c.diagnostic(.variableFromData)?.escalation?.severity, .warning, "DK4046 is a warning when never assigned")
        // §6.5: the design's own examples of messages, in Chinese as the design wrote them.
        t.equal(c.diagnostic(.unknownModifier)?.render(.simplifiedChinese, ["name": "colour", "suggestion": "color"]),
                "没有 `.colour`，是不是想写 `.color`？")
        t.equal(c.diagnostic(.missingOptionsPrefix)?.render(.simplifiedChinese, ["name": "weekStart"]),
                "`weekStart` 是选项，要写成 `options.weekStart`。")
        t.equal(c.diagnostic(.symbolicAnd)?.render(.english, ["fixed": "if a and b"]), "Desk writes `and`: `if a and b`.")
    }

    t.suite("Desk: catalog foreign spellings and units") {
        for row in c.foreign {
            let spec = c.diagnostic(row.diagnostic)
            t.check(spec != nil, "\(row.pattern): \(row.diagnostic.rawValue)")
            t.equal(row.severity, spec?.severity, "\(row.pattern): severity of \(row.diagnostic.rawValue)")
            if case .line(let regex) = row.pattern {
                t.check((try? NSRegularExpression(pattern: regex)) != nil, "\(row.pattern): not a valid pattern")
            }
        }
        // The design's examples and the guessing test: the first thing people write gets its Desk spelling.
        let expected: [(String, String, DiagnosticID)] = [
            ("VStack", "Column", .swiftUIComponent), (".foregroundColor", ".color({0})", .swiftUIModifier),
            (".cornerRadius", ".rounded({0})", .swiftUIModifier), (".fontSize", ".font({0})", .otherFrameworkName),
            (".backgroundColor", ".background({0})", .otherFrameworkName), (".onTap", ".onClick { … }", .otherFrameworkName),
            ("&&", "and", .symbolicAnd), ("FontColor", #".color("{hex}")"#, .rainmeterOption),
            (".colour", ".color({0})", .unknownModifier), ("Bar", "Progress", .unknownComponent),
            (".leading", ".left", .swiftName), (".secondary", ".dim", .swiftName), ("music.artwork", "music.cover", .olderDeskName),
        ]
        for (key, desk, id) in expected {
            let rows = c.index.foreignRows(key)
            t.check(rows.contains { $0.deskText == desk && $0.diagnostic == id }, "\(key): \(rows.map(\.deskText))")
        }
        t.equal(c.index.foreignRows("StringAlign").map(\.context).sorted { $0.rawValue < $1.rawValue },
                [.any, .positionedInFreeform], "StringAlign gives the anchor in a Freeform")
        // Units convert to the dimension's canonical unit.
        func value(_ spelling: String, _ number: Double, base: Int = 1000) -> Double? {
            guard let u = c.unit(spelling: spelling) else { return nil }
            return number * u.factor(base: base) + u.offset
        }
        t.close(value("GB", 2, base: 1024) ?? 0, 2_147_483_648, "2GB next to memory")
        t.close(value("GB", 2) ?? 0, 2_000_000_000, "2GB next to a disk")
        t.close(value("GiB", 1) ?? 0, 1_073_741_824)
        t.close(value("°F", 212) ?? 0, 100, accuracy: 1e-9, "212°F")
        t.close(value("°F", -40) ?? 0, -40, accuracy: 1e-9, "-40°F")
        t.close(value("rad", Double.pi) ?? 0, 180, accuracy: 1e-9)
        t.close(value("km/h", 36) ?? 0, 10, accuracy: 1e-9)
        t.close(value("min", 5) ?? 0, 300)
        t.close(value("ms", 500) ?? 0, 0.5)
        t.close(value("inch", 1) ?? 0, 25.4)
        for u in c.units where u.adoptsBase { t.check(u.basePower != nil, "\(u.spelling): no power") }
        let spellings = Set(c.units.map(\.spelling))
        for m in c.unitMisspellings {
            for s in m.suggestions { t.check(spellings.contains(s), "\(m.spelling) → \(s) is no unit") }
            t.check(c.diagnostic(m.diagnostic) != nil, "\(m.spelling): \(m.diagnostic.rawValue)")
        }
        t.equal(c.index.unitMisspellings["px"]?.diagnostic, .pxUnit)
        t.equal(c.index.unitMisspellings["m"]?.suggestions, ["min"])
        t.equal(c.index.unitMisspellings["mb"]?.suggestions, ["MB", "mbar"])
        t.equal(c.index.unitMisspellings["Mbps"]?.diagnostic, .bitsUnit)
        t.equal(c.index.unitMisspellings["R"]?.diagnostic, .rainmeterRelativePosition)
        // Commands that read an argument as code (§8.2).
        for (command, flag) in [("sh", "-c"), ("zsh", "-c"), ("osascript", "-e"), ("python3", "-c"), ("eval", nil)] as [(String, String?)] {
            t.check(c.rereadingCommands.contains { $0.command == command && $0.codeFlag == flag }, "\(command) \(flag ?? "")")
        }
    }

    t.suite("Desk: catalog language reference") {
        // The reference is generated from the catalog in both languages (§5.1, §9.7); nothing is left out.
        for language in DiagnosticLanguage.allCases {
            let reference = DeskReference.markdown(c, language: language)
            t.equal(reference, DeskReference.markdown(c, language: language), "the same every time")
            for x in c.components { t.check(reference.contains("`\(x.name)`"), "\(language): component \(x.name)") }
            for m in c.modifiers { t.check(reference.contains("`.\(m.name)`"), "\(language): modifier .\(m.name)") }
            for ns in c.namespaces {
                for m in ns.members { t.check(reference.contains("`\(ns.name).\(m.name)"), "\(language): \(ns.name).\(m.name)") }
            }
            for f in c.functions { t.check(reference.contains("`\(f.name)`"), "\(language): \(f.name)") }
            for x in c.controls { t.check(reference.contains("`\(x.name)`"), "\(language): control \(x.name)") }
            for d in c.diagnostics { t.check(reference.contains("| \(d.id.rawValue) |"), "\(language): \(d.id.rawValue)") }
            let tables = reference.split(separator: "\n").filter { $0.hasPrefix("|") }
            t.check(tables.count > 700, "\(language): \(tables.count) table rows")
            if language == .simplifiedChinese {
                t.check(reference.contains("处理器占用率") && reference.contains("内边距"), "the Chinese reference is in Chinese")
            }
            print("  note    reference (\(language.rawValue)): \(reference.utf8.count / 1024) KiB, \(tables.count) table rows")
            // DESK_REFERENCE_DIR=<folder> writes the reference there, to read it or check it in.
            if let folder = ProcessInfo.processInfo.environment["DESK_REFERENCE_DIR"] {
                let url = URL(fileURLWithPath: folder).appendingPathComponent("desk-reference.\(language.rawValue).md")
                t.check((try? reference.write(to: url, atomically: true, encoding: .utf8)) != nil, "writing \(url.path)")
            }
        }
        t.check(DeskReference.parameter(c.component(named: "Grid")!.signatures[0].params[0]) == "columns: Number (1…64) whole",
                "a parameter reads as in the listings")
        t.equal(DeskReference.parameter(c.modifier(named: "padding")!.signatures[0].params[0]), "_ all: Length?")
    }

    t.suite("Desk: catalog lookups are fast enough for the editor") {
        // The editor re-checks 0.3 s after typing stops, parsing and checking the whole file each time (§0.4). The
        // catalog's part of a check is name lookups: here the lookups a checker makes for a 2,000-line widget, and
        // did-you-mean for 100 unknown names. Timings are printed; the bound only catches a pathological slowdown.
        func seconds(_ body: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            return ProcessInfo.processInfo.systemUptime - start
        }
        var fresh = c
        fresh.components = fresh.components           // a copy with its own index, built on first use
        let build = seconds { _ = fresh.index }
        let names = ["Text", "Row", "Progress", "Icon", "Column"]
        let modifierNames = ["font", "color", "padding", "background", "onClick", "hidden", "rounded"]
        let paths = ["cpu.usage", "memory.used", "network.download", "time.now", "battery.level", "music.title"]
        var found = 0
        let lookups = seconds {
            for line in 0..<2_000 {
                if fresh.component(named: names[line % names.count]) != nil { found += 1 }
                if fresh.modifier(named: modifierNames[line % modifierNames.count]) != nil { found += 1 }
                if fresh.modifier(named: modifierNames[(line + 3) % modifierNames.count]) != nil { found += 1 }
                if fresh.member(path: paths[line % paths.count]) != nil { found += 1 }
                if !fresh.implicitMemberTypes(line % 2 == 0 ? "caption" : "left").isEmpty { found += 1 }
                if fresh.member("title", of: .record("MonthGrid"), call: false) != nil { found += 1 }
                if !fresh.index.keywordMatches(line % 2 == 0 ? "percent" : "fontSize").isEmpty { found += 1 }
            }
        }
        t.equal(found, 14_000, "every lookup found")
        // Did-you-mean over every modifier and data member (the edit distance of §6.2 step 5).
        let candidates = (fresh.modifiers.map(\.name) + fresh.namespaces.flatMap { ns in ns.members.map { "\(ns.name).\($0.name)" } })
            .map { Array($0.lowercased().unicodeScalars) }
        let unknown = (0..<100).map { ["fontsiz", "colr", "paddin", "cpu.usag", "memory.use"][$0 % 5] }
        var suggestions = 0
        let didYouMean = seconds {
            for word in unknown {
                let lower = Array(word.lowercased().unicodeScalars)
                let limit = lower.count <= 4 ? 1 : lower.count <= 8 ? 2 : 3
                if candidates.contains(where: { osaDistance(lower, $0, limit: limit) != nil }) { suggestions += 1 }
            }
        }
        t.check(suggestions >= 60, "suggestions: \(suggestions)")
        print(String(format: "  note    catalog: index %.1f ms · 14,000 lookups (a 2,000-line file) %.1f ms · "
                     + "did-you-mean for 100 names over %d candidates %.1f ms", build * 1000, lookups * 1000,
                     candidates.count, didYouMean * 1000))
        t.check(build + lookups + didYouMean < 0.3 * deskCIScale, "the catalog's share of a re-check fits the 0.3 s debounce")
    }
}

/// Whether two parameter types could take the same value (so a value would not know which parameter it fills).
private func typesOverlap(_ a: DeskType, _ b: DeskType) -> Bool {
    if a == b { return true }
    switch (a, b) {
    case (.any, _), (_, .any), (.typeVar, _), (_, .typeVar): return true
    case (.oneOf(let xs), _): return xs.contains { typesOverlap($0, b) }
    case (_, .oneOf(let ys)): return ys.contains { typesOverlap(a, $0) }
    case (.binding(let x), _): return typesOverlap(x, b)
    case (_, .binding(let y)): return typesOverlap(a, y)
    default: break
    }
    let numeric: (DeskType) -> Bool = {
        switch $0 {
        case .number, .anyNumber, .fraction, .lengthSpec: return true
        default: return false
        }
    }
    let textual: (DeskType) -> Bool = {
        switch $0 {
        case .string, .symbolName, .imageSource, .fontFamily, .folderPath, .color, .paint: return true
        default: return false
        }
    }
    if numeric(a) && numeric(b) { return true }
    if textual(a) && textual(b) { return true }
    if case .list = a, case .list = b { return true }
    return false
}

/// Optimal string alignment distance, for the did-you-mean timing; nil when it is more than `limit` (names whose
/// lengths differ by more are skipped at once).
private func osaDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Int? {
    if abs(a.count - b.count) > limit { return nil }
    if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
    var previous2 = [Int](repeating: 0, count: b.count + 1)
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { value = min(value, previous2[j - 2] + 1) }
            current[j] = value
        }
        (previous2, previous, current) = (previous, current, previous2)
    }
    return previous[b.count] <= limit ? previous[b.count] : nil
}
