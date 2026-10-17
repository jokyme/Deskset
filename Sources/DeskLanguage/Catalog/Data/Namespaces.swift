import Foundation

// Data and action namespaces, and the helpers their members are written with. The members themselves are in the
// Namespaces+… files, one per group of the reference.

extension CatalogData {
    static let namespaces: [NamespaceSpec] = systemNamespaces + mediaNamespaces + placeNamespaces + otherNamespaces

    static func namespace(_ name: String, _ titleEn: String, _ titleZh: String, value: MemberSpec? = nil,
                          instanceOf: String? = nil, permission: String? = nil, main: String? = nil,
                          dynamic: Bool = false, _ members: [MemberSpec], doc: Doc) -> NamespaceSpec {
        NamespaceSpec(name: name, title: L(titleEn, titleZh), value: value, instanceOf: instanceOf, permission: permission,
                      mainMember: main, dynamicMembers: dynamic, members: members, doc: doc)
    }

    /// A data field (or a record's field, when it has no cadence of its own).
    static func field(_ name: String, _ titleEn: String, _ titleZh: String, _ type: DeskType, range: RangeSpec = .none,
                      max: MaxCount? = nil, base: Int? = nil, format: FormatDefault? = nil, cadence: Cadence = .ofRecord,
                      sync: Bool = false, permission: String? = nil, settable: Bool = false, twin: String? = nil,
                      lower: DataLowering? = nil, preview: String? = nil, doc: Doc) -> MemberSpec {
        MemberSpec(name: name, kind: .field, title: L(titleEn, titleZh), type: type, range: range, maxCount: max,
                   displayBase: base, defaultFormat: format, cadence: cadence, readsSynchronously: sync,
                   permission: permission, settable: settable, settableTwin: twin,
                   lowering: lower ?? .recordField(name), previewValue: preview, doc: doc)
    }

    /// A data function (`cpu.core(n)`, `weather.at(place)`).
    static func dataFunction(_ name: String, _ titleEn: String, _ titleZh: String, _ signatures: [Signature],
                             _ type: DeskType, range: RangeSpec = .none, max: MaxCount? = nil, base: Int? = nil,
                             format: FormatDefault? = nil, cadence: Cadence = .ofRecord, sync: Bool = false,
                             permission: String? = nil, lower: DataLowering? = nil, preview: String? = nil,
                             doc: Doc) -> MemberSpec {
        MemberSpec(name: name, kind: .function, title: L(titleEn, titleZh), signatures: signatures, type: type,
                   range: range, maxCount: max, displayBase: base, defaultFormat: format, cadence: cadence,
                   readsSynchronously: sync, permission: permission, lowering: lower ?? .recordField(name),
                   previewValue: preview, doc: doc)
    }

    /// An action of a namespace (`music.next()`): nothing is returned, nothing is sampled.
    static func dataAction(_ name: String, _ titleEn: String, _ titleZh: String, _ signatures: [Signature] = [Signature(params: [])],
                           permission: String? = nil, userOnly: Bool = false, command: String, doc: Doc) -> MemberSpec {
        MemberSpec(name: name, kind: .action, title: L(titleEn, titleZh), signatures: signatures, type: .any,
                   cadence: .once, permission: permission, userInitiatedOnly: userOnly, lowering: .action(command),
                   doc: doc)
    }

    // MARK: Lowering

    /// An engine measure with literal options.
    static func measureKernel(_ type: String, _ options: [String: String] = [:], field: String? = nil) -> DataLowering {
        .measure(type: type, options: options.mapValues { .literal($0) }, field: field)
    }

    /// `Measure=Plugin`, `Plugin=name`, with literal options.
    static func pluginKernel(_ name: String, _ options: [String: String] = [:], field: String? = nil) -> DataLowering {
        var all = options.mapValues { OptionTemplate.literal($0) }
        all["Plugin"] = .literal(name)
        return .measure(type: "Plugin", options: all, field: field)
    }

    static func nativeKernel(_ kernel: String, _ options: [String: OptionTemplate] = [:], field: String? = nil) -> DataLowering {
        .native(kernel: kernel, options: options, field: field)
    }

    /// The value of the call's argument with this label (`"_"`: the first positional one).
    static func argument(_ label: String = "_") -> OptionTemplate { .argument(label: label) }
}
