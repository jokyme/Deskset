import Foundation

// What the install sheet asks the user once (§8.1, §8.2): every permission with the catalog's phrase, every host a
// widget may contact, every command it can run — its template, the option each placeholder reads and every value
// the author wrote for it — the features it asks about and the oldest Deskset that runs it, for each widget and for
// the whole folder.

/// A permission the install sheet lists.
public struct DeskConsentPermission: Sendable, Hashable {
    /// `music`, written `.music`.
    public var id: String
    /// Completes "This widget …" / "这个组件要……".
    public var phrase: LocalizedText
    /// The macOS prompt it leads to, if any.
    public var systemPrompt: String?
    /// Asked for in `info.permissions`.
    public var declared: Bool
    /// Something the widget uses needs it (declared or not: DK8101 when not).
    public var needed: Bool
    /// The widgets that ask for or need it.
    public var widgets: [DeskFileID]

    public init(id: String, phrase: LocalizedText, systemPrompt: String?, declared: Bool, needed: Bool, widgets: [DeskFileID]) {
        self.id = id
        self.phrase = phrase
        self.systemPrompt = systemPrompt
        self.declared = declared
        self.needed = needed
        self.widgets = widgets
    }
}

/// A command a widget can run, as the install sheet shows it.
public struct DeskConsentCommand: Sendable, Hashable {
    public struct Placeholder: Sendable, Hashable {
        /// The option it reads (`${1}` is the first).
        public var option: String
        /// The option's default and every constant an action assigns to it, as Desk text.
        public var knownValues: [String]

        public init(option: String, knownValues: [String]) {
            self.option = option
            self.knownValues = knownValues
        }
    }

    public var widget: DeskFileID
    /// As written.
    public var template: String
    /// As it runs, each placeholder a positional parameter (`open "${1}"`).
    public var script: String
    public var placeholders: [Placeholder]
    /// A whole command taken from an option, with the option's default.
    public var scriptOption: String?
    public var scriptDefault: String?
    /// Where it is written.
    public var site: DeskSite?

    public init(widget: DeskFileID, template: String, script: String, placeholders: [Placeholder], scriptOption: String?,
                scriptDefault: String?, site: DeskSite?) {
        self.widget = widget
        self.template = template
        self.script = script
        self.placeholders = placeholders
        self.scriptOption = scriptOption
        self.scriptDefault = scriptDefault
        self.site = site
    }
}

/// What one widget (or the whole folder) needs the user to agree to.
public struct DeskConsent: Sendable, Hashable {
    public var permissions: [DeskConsentPermission]
    /// Host patterns: those `info.network` lists and those the widget's addresses name, sorted.
    public var hosts: [String]
    public var commands: [DeskConsentCommand]
    /// What `supports(…)` asks about, sorted.
    public var features: [String]
    public var minimumAppVersion: AppVersion

    public init(permissions: [DeskConsentPermission] = [], hosts: [String] = [], commands: [DeskConsentCommand] = [],
                features: [String] = [], minimumAppVersion: AppVersion = .deskFirstRelease) {
        self.permissions = permissions
        self.hosts = hosts
        self.commands = commands
        self.features = features
        self.minimumAppVersion = minimumAppVersion
    }

    /// Nothing to ask.
    public var isEmpty: Bool { permissions.isEmpty && hosts.isEmpty && commands.isEmpty }

    /// The sentences of the sheet in a language: one per permission, one per host, one per command.
    public func lines(in language: DiagnosticLanguage) -> [String] {
        var out: [String] = []
        for p in permissions { out.append(p.phrase.text(in: language)) }
        for host in hosts {
            out.append(language == .english ? "connects to \(host)" : "连接 \(host)")
        }
        for c in commands {
            let shown = c.scriptOption.map { "options.\($0)" + (c.scriptDefault.map { " = \($0)" } ?? "") } ?? c.template
            out.append(language == .english ? "runs \(shown)" : "运行 \(shown)")
        }
        return out
    }
}

/// The install sheet of a folder: each widget's consent and the union.
public struct DeskInstallSummary: Sendable, Hashable {
    public var widgets: [DeskFileID: DeskConsent]
    /// The union, permissions in the catalog's order.
    public var total: DeskConsent
    /// Font files the folder adds, with their families when known.
    public var fonts: [DeskPackageFile]
    /// The widget with the highest minimum App version decides the folder's.
    public var minimumAppVersion: AppVersion { total.minimumAppVersion }
}

extension CheckedDeskPackage {
    /// What installing the folder asks the user, per widget and in total. `package.desk`'s own needs (its shared
    /// styles' data) count for every widget that uses the package.
    public func installSummary() -> DeskInstallSummary {
        var perWidget: [DeskFileID: DeskConsent] = [:]
        for file in widgetFiles {
            perWidget[file] = consent(of: [file])
        }
        return DeskInstallSummary(widgets: perWidget, total: consent(of: widgetFiles),
                                  fonts: package.files(.font).filter { !$0.isLink })
    }

    /// The consent of some widgets together.
    func consent(of widgets: [DeskFileID]) -> DeskConsent {
        var consent = DeskConsent()
        var declared: [String: [DeskFileID]] = [:]
        var needed: [String: [DeskFileID]] = [:]
        var hosts = Set<String>()
        var features = Set<String>()
        var minimum = AppVersion.deskFirstRelease
        let packageChecked = checkedPackage
        for file in widgets {
            guard let checked = files[file] else { continue }
            let entry = package.widget(file)
            for p in entry?.permissions ?? [] where !(declared[p]?.contains(file) ?? false) { declared[p, default: []].append(file) }
            for p in checked.requirements.permissions where !(needed[p]?.contains(file) ?? false) { needed[p, default: []].append(file) }
            let patterns = entry?.network ?? []
            hosts.formUnion(patterns)
            // A host the widget names that no listed pattern covers (DK8103) is shown too.
            hosts.formUnion(checked.requirements.hosts.filter { host in !patterns.contains { Checker.hostMatches(host, pattern: $0) } })
            features.formUnion(checked.requirements.features)
            minimum = max(minimum, checked.requirements.minimumAppVersion)
            if let requires = entry?.requires { minimum = max(minimum, requires) }
            if let packageChecked { minimum = max(minimum, packageChecked.requirements.minimumAppVersion) }
            let options = checked.options.merging(packageChecked?.options ?? [:]) { own, _ in own }
            for command in checked.requirements.commands {
                let site = checked.tree.quickResolve(command.node).map { DeskSite(file: file, range: $0.quickTextRange) }
                consent.commands.append(DeskConsentCommand(
                    widget: file, template: command.template, script: command.script,
                    placeholders: command.placeholders.map {
                        DeskConsentCommand.Placeholder(option: $0, knownValues: command.knownValues[$0] ?? [])
                    },
                    scriptOption: command.scriptOption,
                    scriptDefault: command.scriptOption.flatMap { options[$0]?.defaultText },
                    site: site))
            }
        }
        for spec in catalog.permissions where declared[spec.id] != nil || needed[spec.id] != nil {
            var who = (declared[spec.id] ?? []) + (needed[spec.id] ?? [])
            var seen = Set<DeskFileID>()
            who = who.filter { seen.insert($0).inserted }.sorted { DeskPackagePath.precedes($0.path, $1.path) }
            consent.permissions.append(DeskConsentPermission(id: spec.id, phrase: spec.needsPhrase, systemPrompt: spec.systemPrompt,
                                                             declared: declared[spec.id] != nil, needed: needed[spec.id] != nil,
                                                             widgets: who))
        }
        consent.hosts = hosts.sorted()
        consent.features = features.sorted()
        consent.minimumAppVersion = minimum
        return consent
    }
}
