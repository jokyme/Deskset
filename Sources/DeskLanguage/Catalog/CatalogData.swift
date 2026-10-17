import Foundation

/// The catalog's content, written with the small helpers below so each entry reads like a row of the language
/// reference. `DeskCatalog.current` is built from it.
enum CatalogData {
    static let v1 = AppVersion.deskFirstRelease

    // MARK: Text

    static func L(_ en: String, _ zh: String) -> LocalizedText { LocalizedText(en: en, zh: zh) }

    /// Documentation. Where the example harness puts the example follows from its first words unless `context`
    /// says otherwise: `.padding(14)` is a modifier chain, `computed x = …` a declaration, `x = Picker(…)` an
    /// option, `name: "CPU"` a field; anything else is a view.
    static func doc(_ en: String, _ zh: String, _ example: String, _ rainmeter: [RainmeterMapping] = [],
                    keywords: [String] = [], mac: Bool = false, macOS: Int? = nil, rank: Int = 50,
                    context: ExampleContext? = nil) -> Doc {
        Doc(en: en, zh: zh, example: example, exampleContext: context ?? exampleContext(for: example), since: v1,
            macOnly: mac, minimumMacOS: macOS, rainmeter: rainmeter, keywords: keywords, rank: rank)
    }

    static func exampleContext(for example: String) -> ExampleContext {
        let text = example.trimmingCharacters(in: .whitespaces)
        var context = ExampleContext()
        for keyword in ["variable ", "saved ", "computed "] where text.hasPrefix(keyword) {
            context.placement = .declaration
            let rest = text.dropFirst(keyword.count)
            context.replaces = [String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })]
        }
        if context.placement == .view {
            if text.hasPrefix(".") {
                context.placement = .modifiers
            } else if let match = text.range(of: #"^[a-z][A-Za-z0-9]* = [A-Z][A-Za-z]*\("#, options: .regularExpression) {
                context.placement = .optionItem
                context.parent = .options
                context.replaces = [String(text[match].prefix { $0.isLetter || $0.isNumber })]
            } else if let match = text.range(of: #"^[a-z][A-Za-z]*: "#, options: .regularExpression) {
                // A field replaces the harness's field of the same name (it declares every permission, for one).
                context.placement = .infoField
                context.replaces = [String(text[match].dropLast(2))]
            }
        }
        // `.name(x)` declares an element name that replaces the harness's own.
        var search = text[...]
        while let r = search.range(of: ".name(") {
            let name = search[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty, !context.replaces.contains(String(name)) { context.replaces.append(String(name)) }
            search = search[r.upperBound...]
        }
        return context
    }

    // MARK: Rainmeter

    static func meter(_ type: String, _ key: String? = nil, _ value: String? = nil) -> RainmeterMapping {
        RainmeterMapping(.meter(type: type), key: key, value: value)
    }

    /// An option every meter reads.
    static func anyMeter(_ key: String? = nil, _ value: String? = nil) -> RainmeterMapping {
        RainmeterMapping(.meter(type: ""), key: key, value: value)
    }

    static func measure(_ type: String, _ key: String? = nil, _ value: String? = nil) -> RainmeterMapping {
        RainmeterMapping(.measure(type: type, plugin: nil), key: key, value: value)
    }

    /// An option every measure reads.
    static func anyMeasure(_ key: String? = nil, _ value: String? = nil) -> RainmeterMapping {
        RainmeterMapping(.measure(type: "", plugin: nil), key: key, value: value)
    }

    /// `Measure=Plugin`, `Plugin=name`.
    static func plugin(_ name: String, _ key: String? = nil, _ value: String? = nil) -> RainmeterMapping {
        RainmeterMapping(.measure(type: "Plugin", plugin: name), key: key, value: value)
    }

    /// A key of `[Rainmeter]`.
    static func skin(_ key: String, _ value: String? = nil) -> RainmeterMapping {
        RainmeterMapping(.skin, key: key, value: value)
    }

    /// A key of `[Metadata]`.
    static func metadata(_ key: String) -> RainmeterMapping { RainmeterMapping(.metadata, key: key) }

    /// A variable (`MACACCENTCOLOR` for `#MACACCENTCOLOR#`); nil: a variable of the skin's own.
    static func variable(_ name: String? = nil, _ note: String = "") -> RainmeterMapping {
        RainmeterMapping(.variables, key: name, note: note)
    }

    /// A bang (`!SetOption`); nil: a bracketed path or address (`["https://…"]`).
    static func bang(_ name: String?, _ note: String = "") -> RainmeterMapping {
        RainmeterMapping(.bang, key: name, note: note)
    }

    /// `[!CommandMeasure SomeMeasure "command"]` sent to a measure of `measureType`.
    static func commandMeasure(_ measureType: String, _ command: String) -> RainmeterMapping {
        RainmeterMapping(.bang, key: "!CommandMeasure", value: command, fidelity: .approximate,
                         note: "sent to a \(measureType) measure")
    }

    static func contextMenu(_ key: String, _ value: String? = nil) -> RainmeterMapping {
        RainmeterMapping(.contextMenu, key: key, value: value)
    }

    // MARK: Types

    static func e(_ id: String) -> DeskType { .enumeration(id) }
    static func r(_ id: String) -> DeskType { .record(id) }
    static func list(_ t: DeskType) -> DeskType { .list(t) }

    // MARK: Parameters

    /// A positional parameter (`_ name: Type`).
    static func pos(_ name: String, _ type: DeskType, required: Bool = true, def: String? = nil,
                    system: SystemDefault? = nil, range: ClosedRange<Double>? = nil, whole: Bool = false,
                    variadic: Bool = false, sameAs: String? = nil, facets: [FacetID] = [], role: ParamRole = .plain,
                    source: ValueSource = .any, translatable: Bool = false, preview: String? = nil,
                    unit: String? = nil, _ en: String, _ zh: String, page: PageInfo? = nil,
                    rm: [RainmeterMapping] = []) -> ParamSpec {
        param(nil, name, type, required: required, def: def, system: system, defParam: nil, range: range,
              whole: whole, variadic: variadic, sameAs: sameAs, facets: facets, specificity: 0, role: role,
              source: source, translatable: translatable, preview: preview, unit: unit, en, zh, page: page, rm: rm)
    }

    /// A labeled parameter (`label: Type`); its internal name is the label unless `name` says otherwise.
    static func arg(_ label: String, _ type: DeskType, name: String? = nil, required: Bool = false, def: String? = nil,
                    system: SystemDefault? = nil, defParam: String? = nil, range: ClosedRange<Double>? = nil,
                    whole: Bool = false, variadic: Bool = false, sameAs: String? = nil, facets: [FacetID] = [],
                    specificity: Int = 0, role: ParamRole = .plain, source: ValueSource = .any,
                    translatable: Bool = false, preview: String? = nil, unit: String? = nil, _ en: String,
                    _ zh: String, page: PageInfo? = nil, rm: [RainmeterMapping] = []) -> ParamSpec {
        param(label, name ?? label, type, required: required, def: def, system: system, defParam: defParam,
              range: range, whole: whole, variadic: variadic, sameAs: sameAs, facets: facets,
              specificity: specificity, role: role, source: source, translatable: translatable, preview: preview,
              unit: unit, en, zh, page: page, rm: rm)
    }

    private static func param(_ label: String?, _ name: String, _ type: DeskType, required: Bool, def: String?,
                              system: SystemDefault?, defParam: String?, range: ClosedRange<Double>?, whole: Bool,
                              variadic: Bool, sameAs: String?, facets: [FacetID], specificity: Int, role: ParamRole,
                              source: ValueSource, translatable: Bool, preview: String?, unit: String?, _ en: String,
                              _ zh: String, page: PageInfo?, rm: [RainmeterMapping]) -> ParamSpec {
        var defaultValue: DefaultValue?
        if let def { defaultValue = .source(def) }
        if let system { defaultValue = .system(system) }
        if let defParam { defaultValue = .parameter(defParam) }
        return ParamSpec(label: label, name: name, type: type, defaultValue: defaultValue, required: required,
                         range: range, wholeNumber: whole, variadic: variadic, sameAs: sameAs, facets: facets,
                         specificity: specificity, role: role, source: source, translatable: translatable,
                         previewValue: preview, unit: unit ?? displayUnit(of: type), doc: L(en, zh), page: page,
                         rainmeter: rm)
    }

    /// The unit shown after a number field of this type.
    static func displayUnit(of type: DeskType) -> String? {
        switch type {
        case .number(let d): return d == .time ? nil : d.canonicalUnit
        case .fraction: return "%"
        default: return nil
        }
    }

    /// The `if:` parameter of a conditional modifier.
    static func condition(def: String? = nil) -> ParamSpec {
        arg("if", .bool, name: "condition", def: def, role: .condition, "Only while this is true",
            "只在条件成立时")
    }

    static func sig(_ params: ParamSpec..., result: ResultRule? = nil) -> Signature {
        Signature(params: params, result: result, since: v1)
    }

    // MARK: Pages

    static func page(_ section: InspectorCard, _ en: String, _ zh: String, _ control: PageControl,
                     _ level: PageLevel = .more, presets: [PagePreset] = [], long: String? = nil) -> PageInfo {
        PageInfo(section: section, label: L(en, zh), control: control, presets: presets, level: level,
                 longSample: long)
    }

    static func preset(_ value: String, _ en: String, _ zh: String) -> PagePreset { PagePreset(value, L(en, zh)) }

    /// Number presets labeled by themselves.
    static func numbers(_ values: [String]) -> [PagePreset] { values.map { PagePreset($0, L($0, $0)) } }
}

extension RainmeterMapping {
    /// The same mapping, where the behavior differs as the note says.
    func approx(_ note: String = "") -> RainmeterMapping {
        var m = self
        m.fidelity = .approximate
        if !note.isEmpty { m.note = note }
        return m
    }

    /// The same mapping, covering only part of it.
    func partial(_ note: String = "") -> RainmeterMapping {
        var m = self
        m.fidelity = .partial
        if !note.isEmpty { m.note = note }
        return m
    }

    /// The same mapping with a note.
    func noted(_ note: String) -> RainmeterMapping {
        var m = self
        m.note = note
        return m
    }
}
