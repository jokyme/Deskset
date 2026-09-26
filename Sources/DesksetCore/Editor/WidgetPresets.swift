import Foundation

/// The widget page's choices worded by what they do, not by their numbers (docs/editor-friendly.md §8.1.2–§8.1.5,
/// principle P5 "Outcomes, not units"): how often the widget updates, how it stacks with windows, how often its layers
/// redraw, how smooth its transitions are.
public enum WidgetPresets {
    /// One choice of a pop-up: its title, what it writes, and one line about what it means.
    public struct Preset: Equatable {
        public var title: String
        /// The value written (`Update=`, `DefaultUpdateDivider=`…).
        public var value: Int
        public var caption: String

        public init(_ title: String, _ value: Int, _ caption: String = "") {
            self.title = title
            self.value = value
            self.caption = caption
        }
    }

    // MARK: - Update speed (`[Rainmeter] Update=`)

    /// The "How often" pop-up (§8.1.2), in the menu's order; "Custom…" follows them.
    public static let updateSpeeds: [Preset] = [
        Preset("Real-time — 40 times a second", 25, "Smoothest animation. Uses the most battery."),
        Preset("Smooth — 10 times a second", 100, "Smooth. Good for moving bars and graphs."),
        Preset("Every second (standard)", 1000, "Right for clocks and system stats."),
        Preset("Every 5 seconds", 5000, "Saves battery. Clocks with seconds will skip."),
        Preset("Every minute", 60000, "Saves the most battery. Values change once a minute."),
        Preset("Only when it opens", -1, "Never updates by itself."),
    ]

    /// The engine's reading of `Update=` (Skin.readSettings): below 0 means once, otherwise at least 16 ms.
    public static func effectiveUpdate(_ written: Int) -> Int { written < 0 ? -1 : max(written, 16) }

    /// The preset an update interval (milliseconds, as written) matches exactly, if any.
    public static func updatePreset(for milliseconds: Int) -> Preset? {
        let ms = effectiveUpdate(milliseconds)
        return updateSpeeds.first { $0.value == ms }
    }

    /// The title the pop-up shows for an interval: the preset's, else "Custom — 4 times a second" (below a second)
    /// or "Custom — every 2.5 seconds".
    public static func updateTitle(for milliseconds: Int) -> String {
        if let preset = updatePreset(for: milliseconds) { return preset.title }
        return "Custom — " + updateWords(for: milliseconds)
    }

    /// How often, in words: "40 times a second", "every second", "every 2.5 seconds", "only when it opens".
    public static func updateWords(for milliseconds: Int) -> String {
        let ms = effectiveUpdate(milliseconds)
        if ms < 0 { return "only when it opens" }
        if ms < 1000 {
            let perSecond = 1000.0 / Double(ms)
            return "\(number(perSecond, decimals: 1)) times a second"
        }
        if ms == 1000 { return "every second" }
        if ms % 60000 == 0 { return ms == 60000 ? "every minute" : "every \(ms / 60000) minutes" }
        return "every \(number(Double(ms) / 1000, decimals: 2)) seconds"
    }

    /// The caption of an interval: its preset's, else the nearest preset's (by ratio).
    public static func updateCaption(for milliseconds: Int) -> String {
        let ms = effectiveUpdate(milliseconds)
        if ms < 0 { return updateSpeeds.last?.caption ?? "" }
        let timed = updateSpeeds.filter { $0.value > 0 }
        let nearest = timed.min { a, b in
            abs(log(Double(a.value) / Double(ms))) < abs(log(Double(b.value) / Double(ms)))
        }
        return nearest?.caption ?? ""
    }

    /// Extra warnings under the caption (§8.1.2): sound shown by bars moves in jumps at 200 ms or slower; a clock
    /// showing seconds skips at 2 s or slower.
    public static func updateWarnings(for milliseconds: Int, showsSound: Bool, showsSeconds: Bool) -> [String] {
        let ms = effectiveUpdate(milliseconds)
        var warnings: [String] = []
        if showsSound, ms < 0 || ms >= 200 { warnings.append("The sound bars will move in jumps.") }
        if showsSeconds, ms < 0 || ms >= 2000 { warnings.append("The seconds will skip.") }
        return warnings
    }

    /// Milliseconds for a number of seconds typed in the Custom field (at least 16 ms, the engine's minimum).
    public static func milliseconds(fromSeconds seconds: Double) -> Int {
        guard seconds.isFinite else { return 1000 }
        return max(Int((seconds * 1000).rounded()), 16)
    }

    /// Whether a time format shows seconds (`%S`, `%#S`, `%T`, `%X`, `%r`, and the locale time).
    public static func formatShowsSeconds(_ format: String) -> Bool {
        let f = format.replacingOccurrences(of: "%#", with: "%")
        return ["%S", "%T", "%X", "%r"].contains { f.contains($0) } || f.lowercased() == "locale-time"
    }

    // MARK: - Stacking (`AlwaysOnTop`, the desktop setting)

    /// A stacking level with its words.
    public struct Stacking: Equatable {
        public var value: Int
        public var title: String
        public var caption: String

        public init(_ value: Int, _ title: String, _ caption: String) {
            self.value = value
            self.title = title
            self.caption = caption
        }
    }

    /// The three levels of the segmented control (§8.1.3).
    public static let stacking: [Stacking] = [
        Stacking(-2, "On Desktop", "Sits on the desktop, behind all windows."),
        Stacking(0, "Normal", "Windows can cover it, and it can cover them."),
        Stacking(1, "Always on Top", "Stays in front of every window."),
    ]

    /// All five levels, for the pop-up used when the widget is at one of the two in-between levels (§8.1.3).
    public static let stackingAll: [Stacking] = [
        Stacking(-2, "On desktop", "Sits on the desktop, behind all windows."),
        Stacking(-1, "Behind windows", "Stays behind other windows."),
        Stacking(0, "Normal", "Windows can cover it, and it can cover them."),
        Stacking(1, "In front of windows", "Stays in front of every window."),
        Stacking(2, "Always in front", "Stays in front of every window, even when another app asks to be in front."),
    ]

    /// How the stacking control is shown for a value: the three segments, or the five-item pop-up (the value is kept
    /// either way).
    public enum StackingControl: Equatable {
        case segments
        case popup
    }

    public static func stackingControl(for value: Int) -> StackingControl {
        stacking.contains { $0.value == value } ? .segments : .popup
    }

    public static func stackingCaption(for value: Int) -> String {
        stackingAll.first { $0.value == value }?.caption ?? ""
    }

    /// The name of the undo step and toast for a stacking change ("Always on Top", "On Desktop").
    public static func stackingName(for value: Int) -> String {
        stacking.first { $0.value == value }?.title ?? (stackingAll.first { $0.value == value }?.title.capitalized ?? "Stacking")
    }

    // MARK: - Redraw layers (`DefaultUpdateDivider`)

    public static let redrawEvery: [Preset] = [
        Preset("Every update", 1),
        Preset("Every 2nd update", 2),
        Preset("Every 5th update", 5),
        Preset("Only once", -1, "Layers are drawn when the widget opens, then only when an action asks."),
    ]

    public static func redrawTitle(for divider: Int) -> String {
        if let p = redrawEvery.first(where: { $0.value == divider }) { return p.title }
        if divider < 0 { return "Only once" }
        return "Every \(ordinal(divider)) update"
    }

    // MARK: - Transition speed (`TransitionUpdate`)

    public static let transitionSpeeds: [Preset] = [
        Preset("5 frames a second", 200),
        Preset("10 frames a second", 100),
        Preset("20 frames a second", 50),
        Preset("30 frames a second", 33),
        Preset("60 frames a second", 16),
    ]

    public static func transitionTitle(for milliseconds: Int) -> String {
        if let p = transitionSpeeds.first(where: { $0.value == milliseconds }) { return p.title }
        let fps = 1000.0 / Double(max(milliseconds, 1))
        return "\(number(fps, decimals: 1)) frames a second"
    }

    // MARK: - Fade

    /// Fade time in seconds as the field shows it ("0.25").
    public static func fadeSeconds(_ milliseconds: Int) -> String { number(Double(milliseconds) / 1000, decimals: 2) }

    /// `OnHover` choices of the desktop setting.
    public static let onHover: [Preset] = [
        Preset("Do nothing", 0), Preset("Hide", 1), Preset("Fade in", 2), Preset("Fade out", 3),
    ]

    // MARK: - When the widget… (`OnRefreshAction`, `OnUpdateAction`…)

    /// The choices of "When the widget… [No action ▾]" (§8.1.5) besides No action: only those that can't harm. A reload
    /// when the widget opens (`OnRefreshAction`) or updates would make it reload again and again, one while it closes
    /// or on every click (focus) is useless, so only waking from sleep offers it.
    public static func whenTheWidgetChoices(_ key: String) -> [(title: String, action: String)] {
        key.caseInsensitiveCompare("OnWakeAction") == .orderedSame ? [("Reload the widget", "[!Refresh]")] : []
    }

    /// What a right-click menu item does, when the widget page can show it as a choice: reload the widget, open a
    /// website (its address); anything else is shown as a sentence and edited in the code.
    public enum MenuAction: Equatable {
        case reload
        case website(String)
        case other
    }

    public static func menuAction(_ raw: String) -> MenuAction {
        let actions = ActionParser.parse(raw.trimmingCharacters(in: .whitespaces))
        guard actions.count == 1 else { return .other }
        switch actions[0] {
        case .bang(let bang) where bang.name == "refresh" && bang.args.isEmpty:
            return .reload
        case .execute(let target, _):
            let lower = target.lowercased()
            return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? .website(target) : .other
        default:
            return .other
        }
    }

    // MARK: - Doesn't Work on a Mac (`skin.issues` in plain words)

    /// A compatibility note of the widget (`Skin.issues`) in plain words for the widget page (docs/editor-friendly.md
    /// §8.1.5, G3): who it is about, by the name the editor gives it (`name`: a section's display name), what it uses,
    /// and what that means — "“Weather” uses a Windows add-on (WebView.dll), so it stays empty on a Mac." No section
    /// names, option names or engine words; the note as written is for Rainmeter Details. A note not recognised is
    /// reworded where it can be, else said in general terms.
    public static func plainIssue(_ issue: String, in skin: Skin, name: (String) -> String) -> String {
        let text = issue.trimmingCharacters(in: .whitespacesAndNewlines)
        func match(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<max(m.numberOfRanges, 1)).map { i in
                Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
        func quoted(_ section: String) -> String {
            let shown = name(section)
            return shown.hasPrefix("“") ? shown : "“\(shown)”"
        }
        /// "“A”", "“A” and “B”", "“A” and 2 more"; nil for nobody.
        func who(_ sections: [String]) -> (words: String, plural: Bool)? {
            guard let first = sections.first else { return nil }
            switch sections.count {
            case 1: return (quoted(first), false)
            case 2: return ("\(quoted(first)) and \(quoted(sections[1]))", true)
            default: return ("\(quoted(first)) and \(sections.count - 1) more", true)
            }
        }
        /// "“X” uses …, so it stays empty on a Mac." / "“X” and “Y” use …, so they stay empty on a Mac."
        func sentence(_ sections: [String], singular: String, plural: String, tail: String, nobody: String) -> String {
            guard let w = who(sections) else { return nobody }
            let rest = tail.replacingOccurrences(of: "{it}", with: w.plural ? "they" : "it")
                .replacingOccurrences(of: "{stays}", with: w.plural ? "stay" : "stays")
            return "\(w.words) \(w.plural ? plural : singular)\(rest)"
        }
        func plugin(_ raw: String) -> String {
            var n = raw.replacingOccurrences(of: "\\", with: "/")
            if let slash = n.lastIndex(of: "/") { n = String(n[n.index(after: slash)...]) }
            if n.lowercased().hasSuffix(".dll") { n = String(n.dropLast(4)) }
            return n.trimmingCharacters(in: .whitespaces).lowercased()
        }
        func measures(plugin raw: String) -> [String] {
            let wanted = plugin(raw)
            return skin.measures.filter { $0.type == wanted }.map(\.name)
        }
        func measures(type raw: String) -> [String] {
            let wanted = raw.trimmingCharacters(in: .whitespaces).lowercased()
            return skin.measures.filter { ($0.rawOption("Measure") ?? "").trimmingCharacters(in: .whitespaces).lowercased() == wanted }
                .map(\.name)
        }
        func fileName(_ raw: String) -> String {
            let slashed = raw.replacingOccurrences(of: "\\", with: "/")
            return slashed.split(separator: "/").last.map(String.init) ?? slashed
        }

        if let m = match(#"^Plugin "(.+)" is a Windows plugin and is not supported$"#)
            ?? match(#"^Plugin=(.+) is Windows-only and is not supported$"#) {
            return sentence(measures(plugin: m[0]), singular: "uses", plural: "use",
                            tail: " a Windows add-on (\(fileName(m[0]))), so {it} {stays} empty on a Mac.",
                            nobody: "A Windows add-on (\(fileName(m[0]))) doesn't work on a Mac, so what uses it stays empty.")
        }
        if let m = match(#"^Plugin=(.+) is not supported yet$"#) {
            return sentence(measures(plugin: m[0]), singular: "uses", plural: "use",
                            tail: " an add-on Deskset can't run yet (\(fileName(m[0]))), so {it} {stays} empty.",
                            nobody: "An add-on Deskset can't run yet (\(fileName(m[0]))) stays empty.")
        }
        if let m = match(#"^Plugin "(.+)" is provided by the Deskset app and is not available here$"#) {
            return sentence(measures(plugin: m[0]), singular: "uses", plural: "use",
                            tail: " an add-on that only the Deskset app has (\(fileName(m[0]))), so {it} {stays} empty here.",
                            nobody: "An add-on that only the Deskset app has (\(fileName(m[0]))) stays empty here.")
        }
        if let m = match(#"^Measure=(.+) is provided by the Deskset app and is not available here$"#) {
            return sentence(measures(type: m[0]), singular: "reads", plural: "read",
                            tail: " live data that only the Deskset app has (\(m[0])), so {it} {stays} empty here.",
                            nobody: "Live data that only the Deskset app has (\(m[0])) stays empty here.")
        }
        if let m = match(#"^Measure=(.+) is Windows-only and is not supported$"#) {
            return sentence(measures(type: m[0]), singular: "reads", plural: "read",
                            tail: " something only Windows has (\(m[0])), so {it} {stays} empty on a Mac.",
                            nobody: "Something only Windows has (\(m[0])) stays empty on a Mac.")
        }
        if let m = match(#"^Measure=(.+) is not supported( yet)?$"#) {
            return sentence(measures(type: m[0]), singular: "is", plural: "are",
                            tail: " live data Deskset can't read yet (\(m[0])), so {it} {stays} empty.",
                            nobody: "Live data Deskset can't read yet (\(m[0])) stays empty.")
        }
        if let m = match(#"^Meter=(.+) is not supported$"#) {
            let wanted = m[0].trimmingCharacters(in: .whitespaces).lowercased()
            let layers = skin.meters.filter { $0.type == wanted }.map(\.name)
            return sentence(layers, singular: "is", plural: "are",
                            tail: " a kind of layer Deskset can't draw yet (\(m[0])), so {it} doesn't show.",
                            nobody: "A kind of layer Deskset can't draw yet (\(m[0])) doesn't show.")
                .replacingOccurrences(of: "they doesn't", with: "they don't")
        }
        if let m = match(#"^Bang !(\S+) is not supported$"#) {
            let bang = "!" + m[0].lowercased()
            let holder = ([skin.rainmeterSection].compactMap { $0 } + skin.meters as [SkinSection] + skin.measures as [SkinSection])
                .first { section in
                    section.own.entries.contains { $0.value.lowercased().range(of: bang) != nil }
                }
            let doing = "an action that does nothing on a Mac (\(m[0]))."
            guard let holder, !(holder is RainmeterSection) else { return "The widget has \(doing)" }
            return "\(quoted(holder.name)) has \(doing)"
        }
        if match(#"^Lua scripts \(Measure=Script\) are not supported yet$"#) != nil {
            return sentence(measures(type: "Script"), singular: "runs", plural: "run",
                            tail: " a script, which Deskset can't run yet.", nobody: "A script of this widget can't run yet.")
        }
        if let m = match(#"^Script file (.+) of \[(.+)\] not found$"#) {
            return sentence([m[1]], singular: "runs", plural: "run", tail: " a script file that is missing (\(fileName(m[0]))).",
                            nobody: "")
        }
        if let m = match(#"^Script \[(.+)\] was stopped"#) {
            return sentence([m[0]], singular: "runs", plural: "run", tail: " a script that got stuck, so Deskset stopped it.",
                            nobody: "")
        }
        if match(#"^Registry value "#) != nil {
            return sentence(measures(type: "Registry"), singular: "reads", plural: "read",
                            tail: " a Windows setting, so {it} {stays} empty on a Mac.",
                            nobody: "A Windows setting this widget reads stays empty on a Mac.")
        }
        if let m = match(#"^(UsageMonitor|PerfMon) counter (.+) is not available on macOS$"#) {
            return sentence(measures(plugin: m[0]), singular: "reads", plural: "read",
                            tail: " a Windows counter a Mac doesn't have, so {it} {stays} empty.",
                            nobody: "A Windows counter this widget reads stays empty on a Mac.")
        }
        if let m = match(#"^SysInfoType=(.+) is not supported on macOS$"#) {
            let wanted = m[0].lowercased()
            let items = skin.measures.filter { ($0.rawOption("SysInfoType") ?? "").trimmingCharacters(in: .whitespaces).lowercased() == wanted }
            return sentence(items.map(\.name), singular: "asks", plural: "ask",
                            tail: " for system information a Mac doesn't have (\(m[0])), so {it} {stays} empty.",
                            nobody: "System information a Mac doesn't have (\(m[0])) stays empty.")
        }
        if let m = match(#"^WebParser Flags=(.+) is not supported$"#) {
            return sentence(measures(type: "WebParser") + measures(plugin: "WebParser"), singular: "uses", plural: "use",
                            tail: " a download setting Deskset ignores (\(m[0])).", nobody: "A download setting Deskset ignores (\(m[0])).")
        }
        if match(#"^Histogram .*(ImageRotate|ColorMatrix)"#) != nil {
            return sentence(skin.meters.filter { $0.type == "histogram" }.map(\.name), singular: "uses", plural: "use",
                            tail: " picture rotation or color adjustment, which Deskset ignores.",
                            nobody: "A bar graph uses picture rotation or color adjustment, which Deskset ignores.")
        }
        return plainWords(text)
    }

    /// A note written for people already ("Allow Deskset in System Settings…"), with engine words taken out: a leading
    /// "Name: " of the add-on that wrote it, `Key=` before a value, "skin" → "widget". Still technical after that: a
    /// general sentence.
    static func plainWords(_ text: String) -> String {
        var t = text
        if let colon = t.range(of: ": "), !t[..<colon.lowerBound].contains(" "), t[..<colon.lowerBound].count < 24 {
            t = String(t[colon.upperBound...])
        }
        t = t.replacingOccurrences(of: #"\b[A-Za-z]+=(?=\S)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\bskins\b"#, with: "widgets", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\bskin\b"#, with: "widget", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\bSkin\b"#, with: "Widget", options: .regularExpression)
        let firstWord = t.prefix { $0 != " " }
        if !firstWord.isEmpty, firstWord.allSatisfy({ $0.isLowercase }) { t = firstWord.capitalized + t.dropFirst(firstWord.count) }
        if isEngineText(t) { return "Part of this widget doesn't work on a Mac." }
        return t
    }

    /// Whether text uses the words the default UI never shows (docs/editor-friendly.md §3.3): skin, meter, measure,
    /// section, variable, MeterStyle, ms, INI, .inc, .ini, f(x), Refresh, a `#Name#`, a `[Section]`, `R,G,B`.
    public static func isEngineText(_ text: String) -> Bool {
        EditorSchema.engineWord(in: text) != nil
    }

    // MARK: - Words

    /// A number with at most `decimals` decimals, without trailing zeros (POSIX: skins are code, so is this).
    public static func number(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "0" }
        var s = String(format: "%.\(max(decimals, 0))f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// "2nd", "3rd", "11th".
    public static func ordinal(_ n: Int) -> String {
        let tens = (n / 10) % 10, ones = n % 10
        let suffix = tens == 1 ? "th" : ones == 1 ? "st" : ones == 2 ? "nd" : ones == 3 ? "rd" : "th"
        return "\(n)\(suffix)"
    }
}
