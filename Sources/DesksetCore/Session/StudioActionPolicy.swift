import Foundation

/// What the Studio's own instance of a widget may do of its actions: a filter of bangs, until the engine records side
/// effects itself. The widget on the desktop runs next to it and does everything for real, so this one runs only what
/// stays inside the widget — options, variables, meters and measures shown, hidden, updated; its own animation timers
/// and scripts — and records the rest instead of doing it twice: opening web pages, files and programs, writing files
/// (`!WriteKeyValue`), the window (`!Move`, `!Hide`, …), other widgets, the app, and commands to measures that act
/// outside the widget (`RunCommand`, players, the volume, the Trash…). A bang whose Config argument names another
/// widget is recorded too.
///
/// What its plugins and scripts do outside the widget on their own goes to a recording (`sideEffects`, the skin's side
/// effects under this policy): the files its scripts write (`io.open` for writing, `io.output`, `os.remove`,
/// `os.rename`), what its WebParser measures save to a `DownloadFile` or dump go to a private copy (`fileSandbox`), so
/// the scripts go on as they would, reading back what they wrote, and the widget's files are left to the desktop copy;
/// programs, the Mac's audio and players are only recorded. Each is recorded here too (`.file` for a file, `.effect`
/// for the rest).
///
/// While the Studio designs, clicks never reach the instance: only its measures' actions (OnUpdateAction,
/// IfCondition…) and scripts run. The same policy guards the interactive preview of later stages, where clicks do.
public final class StudioActionPolicy: SkinActionPolicy {
    /// An action that was not run.
    public struct Recorded: Equatable, CustomStringConvertible {
        public enum Kind: Equatable {
            case bang
            /// A web page, file or program (`["https://…"]`).
            case execute
            /// A file a script or a download wrote, removed or renamed: kept in the private copy (`fileSandbox`).
            case file
            /// Something else a plugin would have done outside the widget (a program, the audio, a player).
            case effect
        }

        public var kind: Kind
        /// As a skin would write it: `!WriteKeyValue Variables Theme dark`, `https://example.com`.
        public var text: String
        /// The canonical bang name (`writekeyvalue`), or the target for `execute`.
        public var name: String

        public var description: String { text }
    }

    /// The actions recorded, oldest first (the last `limit`).
    public private(set) var recorded: [Recorded] = []
    /// How many recorded actions are kept.
    public var limit = 100
    /// Told of each recorded action (the Studio can say what the widget would do).
    public var onRecord: ((Recorded) -> Void)?

    public init() {}

    /// What the instance's plugins and scripts do outside it: recorded, its file writes kept in a private copy (made on
    /// first use).
    public var sideEffects: SideEffects? {
        hasEffects = true
        return effects
    }

    /// Where the instance's file writes go.
    public var fileSandbox: SkinFileSandbox? { sideEffects?.fileSandbox }

    private lazy var effects: RecordingSideEffects = {
        let effects = RecordingSideEffects()
        effects.onRecord = { [weak self] effect in self?.record(effect) }
        return effects
    }()
    private var hasEffects = false

    /// A new instance starts from the widget's real files (as the desktop copy does when it reloads): the private copy
    /// of the files is forgotten.
    public func resetFiles() {
        guard hasEffects else { return }
        effects.reset()
    }

    /// A side effect as the Studio lists it: a file change as the sandbox says it (`write …`, `os.remove …`), the rest as
    /// the effect says it.
    private func record(_ effect: SideEffect) {
        switch effect {
        case .writeFile(let path):
            record(Recorded(kind: .file, text: "write \(path)", name: "write"))
        case .removeFile(let path):
            record(Recorded(kind: .file, text: "os.remove \(path)", name: "remove"))
        case .renameFile(let from, let to):
            record(Recorded(kind: .file, text: "os.rename \(from) \(to)", name: "rename"))
        case .writeKeyValue:
            record(Recorded(kind: .file, text: effect.description, name: "writekeyvalue"))
        default:
            record(Recorded(kind: .effect, text: effect.description, name: String(effect.description.prefix { $0 != " " })))
        }
    }

    public func skin(_ skin: Skin, allows bang: Bang) -> Bool {
        guard Self.staysInside(bang, in: skin) else {
            record(Recorded(kind: .bang, text: Self.text(of: bang), name: bang.name))
            return false
        }
        return true
    }

    public func skin(_ skin: Skin, allowsExecuting target: String, arguments: [String]) -> Bool {
        record(Recorded(kind: .execute, text: ([target] + arguments).map(Self.quoted).joined(separator: " "), name: target))
        return false
    }

    public func clearRecorded() { recorded = [] }

    private func record(_ action: Recorded) {
        recorded.append(action)
        if recorded.count > limit { recorded.removeFirst(recorded.count - limit) }
        onRecord?(action)
    }

    // MARK: What stays inside the widget

    /// Bangs whose effect stays inside the widget (with no Config argument naming another one).
    static let insideBangs: Set<String> = [
        "setoption", "setoptiongroup", "setvariable",
        "update", "redraw", "delay", "log",
        "updatemeter", "updatemetergroup", "updatemeasure", "updatemeasuregroup", "movemeter",
        "showmeter", "hidemeter", "togglemeter", "showmetergroup", "hidemetergroup", "togglemetergroup",
        "enablemeasure", "disablemeasure", "togglemeasure", "enablemeasuregroup", "disablemeasuregroup",
        "togglemeasuregroup", "pausemeasure", "unpausemeasure", "togglepausemeasure", "pausemeasuregroup",
        "unpausemeasuregroup", "togglepausemeasuregroup",
        "disablemouseaction", "clearmouseaction", "enablemouseaction", "togglemouseaction",
        "disablemouseactiongroup", "clearmouseactiongroup", "enablemouseactiongroup", "togglemouseactiongroup",
    ]

    /// Measures (their `Measure=` type or plugin name, lowercased) whose `!CommandMeasure` commands stay inside the
    /// widget: timers and scripts that animate it, readers of data. Any other measure's commands — running programs,
    /// players, the volume, files and folders, the Trash, windows of their own — are recorded, and so is a measure
    /// this list does not know yet.
    static let insideCommandMeasures: Set<String> = [
        // Built in.
        "calc", "time", "uptime", "cpu", "memory", "physicalmemory", "swapmemory", "netin", "netout", "nettotal",
        "freediskspace", "loop", "string", "process", "sysinfo", "webparser", "powerplugin", "registry", "script",
        // Plugins of the engine.
        "actiontimer", "coretemp", "advancedcpu", "pingplugin", "ping", "quoteplugin", "quote", "folderinfo",
        "usagemonitor", "perfmon", "perfmonplugin", "resmon", "speedfanplugin", "speedfan", "mouse", "slider",
        "msiafterburner", "macsensors", "macweather", "macsun",
        // Plugins of the app that only read.
        "audiolevel", "wifistatus", "chameleon", "isfullscreen", "getactivetitle", "syscolor",
    ]

    /// Whether `bang` changes nothing outside `skin`.
    public static func staysInside(_ bang: Bang, in skin: Skin) -> Bool {
        let name = bang.name
        if name == "commandmeasure" || name == "pluginbang" {
            guard targetsOnlyItself(bang, in: skin) else { return false }
            let measureName: String
            if name == "pluginbang", bang.args.count < 2 {
                measureName = (bang.args.first ?? "").trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            } else {
                measureName = bang.args.first ?? ""
            }
            // A measure the widget does not have: the engine logs it and does nothing.
            guard let measure = skin.measure(named: measureName) else { return true }
            return insideCommandMeasures.contains(measure.type.lowercased())
        }
        guard insideBangs.contains(name) else { return false }
        return targetsOnlyItself(bang, in: skin)
    }

    /// No Config argument, or one naming this widget (or `*`: every widget, this one included — the engine performs
    /// it here and hands the rest to the host, which does not pass it on from the Studio's instance).
    static func targetsOnlyItself(_ bang: Bang, in skin: Skin) -> Bool {
        guard let definition = BangCatalog.definition(for: bang.name),
              let config = definition.configArgument(in: bang.args) else { return true }
        if config == "*" { return true }
        return config.replacingOccurrences(of: "/", with: "\\").caseInsensitiveCompare(skin.config) == .orderedSame
    }

    /// `!Name arg "arg with spaces"`.
    static func text(of bang: Bang) -> String {
        let name = BangCatalog.definition(for: bang.name)?.displayName ?? "!\(bang.name)"
        return ([name] + bang.args.map(quoted)).joined(separator: " ")
    }

    static func quoted(_ s: String) -> String {
        s.isEmpty || s.contains(where: { $0 == " " || $0 == "\t" }) ? "\"\(s)\"" : s
    }
}
