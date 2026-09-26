import Foundation

/// Actions (bangs) in plain sentences, and the few kinds of click the inspector can build (docs/editor-friendly.md
/// §8.2 "Click actions"): "Opens “Activity Monitor”", "Opens example.com", "Shows or hides “Audio”", "Runs 2 commands".
/// What the picker cannot read back exactly is `ClickAction.custom` and is never rewritten.
public enum ActionSummary {
    /// One sentence for an action option's value. `name` gives a layer's name as the editor shows it ("“Audio”",
    /// "Bar 6"); `color` a color value's name ("Bar color"); `section` is the layer the action belongs to ("its
    /// text"). nil for an empty value.
    public static func sentence(for action: String, section: String? = nil, name: (String) -> String,
                                color: (String) -> String = { _ in "a new color" }) -> String? {
        let actions = ActionParser.parse(action)
        guard !actions.isEmpty else {
            return action.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "Runs a command"
        }
        // What the picker writes (a bang followed by a redraw) reads as the bang alone.
        let meaningful = actions.filter { a in
            if case .bang(let b) = a { return !["redraw", "update", "updatemeter", "updatemeasure"].contains(b.name) }
            return true
        }
        if meaningful.count > 1 {
            if let hover = hoverColorSentence(meaningful, section: section, color: color) { return hover }
            return "Runs \(meaningful.count) commands"
        }
        guard let only = meaningful.first ?? actions.first else { return nil }
        return sentence(for: only, section: section, name: name, color: color)
    }

    /// A sentence using the skin's layer names (`LayerNaming`).
    public static func sentence(for action: String, section: String? = nil, in skin: Skin) -> String? {
        let namer = LayerNaming.namer(for: skin)
        return sentence(for: action, section: section, name: { s in
            skin.meter(named: s).map { namer.layer($0).title } ?? "“\(s)”"
        }, color: { value in
            SkinInspection.referencedVariables(in: value).first.map { LayerNaming.humanized($0).lowercased() } ?? "a new color"
        })
    }

    static func sentence(for action: SkinAction, section: String?, name: (String) -> String,
                         color: (String) -> String) -> String {
        switch action {
        case .execute(let target, _):
            return opens(target)
        case .bang(let b):
            let first = b.args.first ?? ""
            switch b.name {
            case "togglemeter": return "Shows or hides \(name(first))"
            case "showmeter": return "Shows \(name(first))"
            case "hidemeter": return "Hides \(name(first))"
            case "togglemetergroup": return "Shows or hides the layers in “\(first)”"
            case "showmetergroup": return "Shows the layers in “\(first)”"
            case "hidemetergroup": return "Hides the layers in “\(first)”"
            case "toggleconfig", "activateconfig", "deactivateconfig":
                let widget = first.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? first
                let verb = b.name == "toggleconfig" ? "Shows or hides" : b.name == "activateconfig" ? "Shows" : "Hides"
                return "\(verb) the widget “\(widget)”"
            case "refresh": return "Reloads the widget"
            case "refreshapp": return "Reloads every widget"
            case "setvariable": return "Changes the shared value “\(first)”"
            case "setoption":
                // A color of the layer itself (by its name or as #CURRENTSECTION#): "Turns its text Bar color".
                if b.args.count >= 3, b.args[1].lowercased().hasSuffix("color"),
                   let sentence = hoverColorSentence([action], section: section, color: color) {
                    return sentence
                }
                if first.caseInsensitiveCompare("#CURRENTSECTION#") == .orderedSame
                    || section.map({ first.caseInsensitiveCompare($0) == .orderedSame }) == true {
                    return "Changes one of its settings"
                }
                return "Changes a setting of \(name(first))"
            case "show", "showfade": return "Shows the widget"
            case "hide", "hidefade": return "Hides the widget"
            case "toggle", "togglefade": return "Shows or hides the widget"
            case "move": return "Moves the widget"
            case "commandmeasure": return "Sends a command to live data"
            case "log": return "Writes to the log"
            case "quit": return "Quits Deskset"
            case "manage": return "Opens Manage Widgets"
            case "skinmenu": return "Opens the widget's menu"
            default: return "Runs a command"
            }
        }
    }

    /// `[!SetOption Self FontColor X][!SetOption …]`: "Turns its text Bar color" for a change of color on hover.
    static func hoverColorSentence(_ actions: [SkinAction], section: String?, color: (String) -> String) -> String? {
        guard actions.count == 1, case .bang(let b) = actions[0], b.name == "setoption", b.args.count >= 3 else { return nil }
        // The layer itself: by its name, or as `#CURRENTSECTION#` (a look shared by several layers writes it so).
        let target = b.args[0].trimmingCharacters(in: .whitespaces)
        guard target.caseInsensitiveCompare("#CURRENTSECTION#") == .orderedSame
                || section.map({ target.caseInsensitiveCompare($0) == .orderedSame }) == true else { return nil }
        let value = b.args[2].trimmingCharacters(in: .whitespaces)
        // An empty value takes the option back to what the layer (or its look) sets.
        if value.isEmpty { return "Turns its \(colorPart(b.args[1])) back to its usual color" }
        return "Turns its \(colorPart(b.args[1])) \(color(value))"
    }

    /// FontColor → "text", BarColor → "fill", SolidColor → "background", LineColor → "line".
    static func colorPart(_ key: String) -> String {
        switch key.lowercased() {
        case "fontcolor": return "text"
        case "barcolor": return "fill"
        case "solidcolor": return "background"
        case "linecolor": return "line"
        default: return "color"
        }
    }

    /// "Opens example.com", "Opens “Activity Monitor”", "Opens “notes.txt”".
    static func opens(_ target: String) -> String {
        let t = target.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           var host = url.host {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return "Opens \(host)"
        }
        if t.lowercased().hasPrefix("mailto:") { return "Writes an email to \(t.dropFirst(7))" }
        let normalized = t.replacingOccurrences(of: "\\", with: "/")
        var last = (normalized as NSString).lastPathComponent
        if last.lowercased().hasSuffix(".app") { last = String(last.dropLast(4)) }
        return last.isEmpty ? "Opens a file" : "Opens “\(last)”"
    }
}

/// What a click (or pointing at a layer) does, as the WHEN CLICKED card's picker offers it (docs/editor-friendly.md
/// §8.2). `parse` reads only what `text` writes (and the same thing written by hand); everything else is `.custom`
/// and stays exactly as written.
public enum ClickAction: Equatable {
    case nothing
    /// `["https://example.com"]`.
    case openWebsite(String)
    /// `["/Applications/Calculator.app"]`.
    case openApp(String)
    /// `["/Users/me/Notes.txt"]`.
    case openFile(String)
    /// `[!ToggleMeter Name][!Redraw]`.
    case toggleLayer(String)
    /// `[!ShowMeter Name][!Redraw]` (pointing at a layer shows another; leaving hides it again).
    case showLayer(String)
    /// `[!ToggleConfig "Config" "File.ini"]`.
    case toggleWidget(config: String, file: String)
    /// `[!Refresh]`.
    case reload
    /// `[!SetOption Self Key Color][!UpdateMeter Self][!Redraw]` (pointed at: change color).
    case changeColor(section: String, key: String, color: String)
    /// Anything else, as written.
    case custom(String)

    public static func parse(_ raw: String) -> ClickAction {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .nothing }
        let parsed = ActionParser.parseDetailed(text)
        guard !parsed.isEmpty else { return .custom(raw) }
        var actions = parsed.map(\.action)
        // A trailing redraw (and a meter update) is part of what the picker writes.
        func isRedraw(_ a: SkinAction) -> Bool { if case .bang(let b) = a { return b.name == "redraw" }; return false }
        func isUpdate(_ a: SkinAction) -> Bool { if case .bang(let b) = a { return b.name == "updatemeter" }; return false }
        let candidate: ClickAction
        switch actions.first! {
        case .execute(let target, let args) where args.isEmpty && actions.count == 1:
            let t = target.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                candidate = .openWebsite(t)
            } else if t.lowercased().hasSuffix(".app") || t.lowercased().hasSuffix(".app/") {
                candidate = .openApp(t)
            } else if t.hasPrefix("/") || t.hasPrefix("~") {
                candidate = .openFile(t)
            } else {
                return .custom(raw)
            }
        case .bang(let b):
            if actions.count > 1, isRedraw(actions.last!) { actions.removeLast() }
            if b.name == "setoption", b.args.count == 3, actions.count == 2, isUpdate(actions[1]),
               case .bang(let u) = actions[1], u.args.first?.caseInsensitiveCompare(b.args[0]) == .orderedSame {
                candidate = .changeColor(section: b.args[0], key: b.args[1], color: b.args[2])
                break
            }
            guard actions.count == 1 else { return .custom(raw) }
            switch b.name {
            case "togglemeter" where b.args.count == 1: candidate = .toggleLayer(b.args[0])
            case "showmeter" where b.args.count == 1: candidate = .showLayer(b.args[0])
            case "toggleconfig" where b.args.count == 2: candidate = .toggleWidget(config: b.args[0], file: b.args[1])
            case "refresh" where b.args.isEmpty: candidate = .reload
            default: return .custom(raw)
            }
        default:
            return .custom(raw)
        }
        // Only what reads back the same is the picker's: nothing written differently is ever rewritten.
        return normalized(candidate.text) == normalized(text) ? candidate : .custom(raw)
    }

    /// The action text to write (empty for `.nothing`).
    public var text: String {
        func quoted(_ s: String) -> String { s.contains(" ") || s.contains("\"") || s.isEmpty ? "\"\(s)\"" : s }
        switch self {
        case .nothing: return ""
        case .openWebsite(let u), .openApp(let u), .openFile(let u): return "[\"\(u)\"]"
        case .toggleLayer(let m): return "[!ToggleMeter \(quoted(m))][!Redraw]"
        case .showLayer(let m): return "[!ShowMeter \(quoted(m))][!Redraw]"
        case .toggleWidget(let config, let file): return "[!ToggleConfig \"\(config)\" \"\(file)\"]"
        case .reload: return "[!Refresh]"
        case .changeColor(let s, let key, let color):
            return "[!SetOption \(quoted(s)) \(key) \(quoted(color))][!UpdateMeter \(quoted(s))][!Redraw]"
        case .custom(let raw): return raw
        }
    }

    /// Compares the way the engine reads it: whitespace between brackets and in bang words does not matter.
    static func normalized(_ text: String) -> String {
        ActionParser.parseDetailed(text).map { "\($0.action)" }.joined(separator: "|")
    }
}
