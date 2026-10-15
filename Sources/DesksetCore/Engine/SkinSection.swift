import Foundation

/// Common base of measures, meters and the `[Rainmeter]` section: option lookup with MeterStyle inheritance,
/// `!SetOption` overrides, variable resolution, UpdateDivider and Group bookkeeping.
///
/// Manual rules implemented here (docs.rainmeter.net/manual/meters/general-options/meterstyles/,
/// /manual/measures/general-options/, tips "!SetOption Guide", /manual/variables/):
/// - Option lookup order: `!SetOption` value, the section's own key, then MeterStyles — "options on later parents
///   override those on earlier parents". Styles are only consulted by meters (`styles` stays empty otherwise).
/// - `!SetOption Section Option ""` "removes the entire option from the meter or measure": the section's own key is
///   ignored from then on, so a MeterStyle value (or the option's default) applies again. An empty value in the file
///   is not a setting either (see `rawOption`).
/// - Inherited options are resolved as if written in the child (`#CURRENTSECTION#` is the child's name).
/// - Values are resolved with `#Variables#` always. `[SectionVariables]` are resolved on every read of a
///   `DynamicVariables=1` section, and otherwise in the reads after the skin loaded (the first update, `!SetOption`),
///   so they keep the value they had then (see `readOptionsIfNeeded`).
open class SkinSection {
    public let name: String
    /// Compatibility for sections constructed by Skin. Independent kernels use sectionContext instead;
    /// they have no Skin to return. The owner must remain alive while any section is used.
    public final var skin: Skin {
        guard let skin = sectionContext as? Skin else {
            preconditionFailure("A section constructed with an independent context has no Skin")
        }
        return skin
    }
    unowned let sectionContext: any SectionContext
    /// The current host, read on this section's owner when an app plugin asks for a service.
    package var serviceHost: SkinHost? { sectionContext.host }
    /// The section as the skin's files write it. A patch of the running skin (`Skin.patch`) puts the new text's section
    /// in its place; the lookup below follows.
    var own: IniSection {
        get { optionStack.own }
        set { optionStack.own = newValue }
    }
    let optionStack: OptionStack
    /// `!SetOption` values, keyed by lowercased option name (raw, resolved when read). An empty value marks an
    /// option removed with `!SetOption … ""`.
    var overrides: [String: String] {
        get { optionStack.overrides }
        set { optionStack.overrides = newValue }
        // Preserve direct dictionary mutations without a get/copy/set round trip.
        _modify { yield &optionStack.overrides }
    }
    /// MeterStyle section names (meters only), resolved at option-read time.
    var styles: [String] {
        get { optionStack.styles }
        set { optionStack.styles = newValue }
        _modify { yield &optionStack.styles }
    }

    public internal(set) var dynamicVariables = false
    public internal(set) var updateDivider = 1
    public internal(set) var groups: [String] = []
    /// Set by `!SetOption` and on load; dynamic sections re-read every update anyway.
    var needsOptionRead = true
    var updateTick = 0

    /// Mouse action state bangs (meters and `[Rainmeter]` only). Missing entries are `.enabled`.
    var mouseActionStates: [MouseEventKind: MouseActionState] = [:] {
        didSet { if mouseActionStates != oldValue { sectionContext.noteSnapshotChange() } }
    }
    /// The last non-enabled state per action, used by `!ToggleMouseAction` ("remembers the last non-enabled
    /// state"; disabled by default).
    var lastNonEnabledMouseState: [MouseEventKind: MouseActionState] = [:]

    init(name: String, section: IniSection, skin: Skin) {
        self.name = name
        self.optionStack = OptionStack(own: section)
        self.sectionContext = skin
    }

    /// The context owns its sections; this reverse reference is borrowed, just as it is for Skin.
    init(name: String, section: IniSection, context: any SectionContext) {
        self.name = name
        self.optionStack = OptionStack(own: section)
        self.sectionContext = context
    }

    // MARK: Raw option lookup

    /// Option value as written (before variables are resolved): `!SetOption` override, own key, then MeterStyles
    /// (later styles win over earlier ones).
    ///
    /// An empty value does not count as set, wherever it is written: `!SetOption … ""` "removes the entire option from
    /// the meter or measure", "thus allowing the MeterStyle setting on the meter to again control this option" (the
    /// !SetOption guide), and without a style the option's default applies ("the meter has no FontColor setting at
    /// all, and will default to 0,0,0,255"). The MeterStyles page does not treat empty values specially; judgment:
    /// an empty value in the skin file (`FontColor=` in the meter, or in a later style) behaves the same way, so the
    /// lookup continues with the (earlier) styles. When no style has a value, an empty own / style value is returned
    /// as `""` (the option is present but empty); an option removed with `!SetOption` is nil.
    public func rawOption(_ key: String) -> String? {
        optionStack.rawOption(key, styleValues: { self.sectionContext.styleValues(named: $0) })
    }

    static let optionAliases = OptionStack.optionAliases

    /// The value of `key` as the skin's files define it — the section's own value, else its MeterStyles' (the last
    /// listed first) — ignoring what is set while the skin runs (`!SetOption`, the editor's live previews). nil when
    /// no file sets it; `""` for an empty value.
    public func fileOption(_ key: String) -> String? {
        optionStack.fileOption(key, styleValues: { self.sectionContext.styleValues(named: $0) })
    }

    /// The value of `key` the section's MeterStyles give it (the last listed first) — what `fileOption(key)` becomes
    /// when the section's own key is removed. nil when no style sets it; `""` for an empty value.
    public func styleFileOption(_ key: String) -> String? {
        optionStack.styleFileOption(key, styleValues: { self.sectionContext.styleValues(named: $0) })
    }

    /// Where `fileOption(key)` is defined: the section itself or the MeterStyle it inherits it from (nil when no file
    /// sets it). Unlike `optionOrigin`, never `.setOption`.
    public func fileOrigin(_ key: String) -> OptionOrigin? {
        optionStack.fileOrigin(key, sectionName: name,
                               styleValues: { self.sectionContext.styleValues(named: $0) },
                               styleName: { self.sectionContext.styleSection(named: $0)?.name },
                               location: { self.sectionContext.sources.location(section: $0, key: $1) })
    }

    /// Entries keyed by lowercased name; the first definition of a key wins.
    static func index(_ section: IniSection) -> [String: String] { OptionStack.index(section) }

    /// Option value with variables and — for dynamic sections, and in every read after the skin loaded — section
    /// variables resolved (see `readOptionsIfNeeded`).
    public func option(_ key: String) -> String? {
        guard let raw = rawOption(key) else { return nil }
        let sectionVariables = resolvesSectionVariables
        let value = sectionContext.resolve(raw, in: self, sectionVariables: sectionVariables)
        noteSectionVariables(raw: raw, resolved: value, sectionVariablesResolved: sectionVariables)
        return value
    }

    /// Sets `mentionsSectionVariables` when an option read now names a measure or meter in brackets: from the value
    /// read, when section variables were not resolved in it (the load-time read); otherwise — while a patch reads the
    /// section (`tracksSectionVariables`) — from the value with only variables resolved.
    func noteSectionVariables(raw: String, resolved: String, sectionVariablesResolved: Bool) {
        guard !mentionsSectionVariables else { return }
        if !sectionVariablesResolved {
            if resolved.utf8.contains(UInt8(ascii: "[")) { mentionsSectionVariables = sectionContext.mentionsSectionVariable(resolved) }
        } else if tracksSectionVariables,
                  raw.utf8.contains(UInt8(ascii: "[")) || raw.utf8.contains(UInt8(ascii: "#")) {
            let plain = sectionContext.resolve(raw, in: self, sectionVariables: false)
            if plain.utf8.contains(UInt8(ascii: "[")) { mentionsSectionVariables = sectionContext.mentionsSectionVariable(plain) }
        }
    }

    /// Whether options read now resolve `[Measure]` / `[Meter:X]` section variables.
    var resolvesSectionVariables: Bool { dynamicVariables || readingAfterLoad }

    /// True while `readOptions()` runs after the skin's load-time read (see `readOptionsIfNeeded`).
    private(set) var readingAfterLoad = false
    /// Set when an option read without section variables names a measure or meter in brackets; the skin then
    /// reads the section's options once more at the first update (see `Skin.load`), and a patch reads it again when
    /// another section changed (`Skin.patch(sources:)`).
    var mentionsSectionVariables = false
    /// True while a patch reads the section's new options: `mentionsSectionVariables` is found anew from them, although
    /// that read resolves section variables (`rereadTrackingSectionVariables`).
    private(set) var tracksSectionVariables = false

    /// Reads the options again after a patch changed them, finding anew whether they name measures or meters in
    /// brackets: a reload would find that in its load-time read, and later patches read such a section again.
    func rereadTrackingSectionVariables() {
        mentionsSectionVariables = false
        needsOptionRead = true
        tracksSectionVariables = true
        defer { tracksSectionVariables = false }
        readOptionsIfNeeded()
    }

    /// Whether option `key`, which failed to parse in this read, may still be valid once section variables have
    /// their values: it names a measure or meter in brackets (`Formula=[Meter:X] + 5`), and this read either did not
    /// resolve section variables (the load-time read of a section without DynamicVariables) or ran while the skin
    /// was loading (no measure has a value and no meter a position yet). Such options are read again at the first
    /// update, so "invalid …" log lines wait for that read instead of reporting a mistake the skin does not have.
    func awaitsSectionVariables(_ key: String) -> Bool {
        if resolvesSectionVariables && sectionContext.optionsLoaded { return false }
        guard let raw = rawOption(key), raw.utf8.contains(UInt8(ascii: "[")) else { return false }
        return sectionContext.mentionsSectionVariable(sectionContext.resolve(raw, in: self, sectionVariables: false))
    }

    /// Action option (`LeftMouseUpAction`, `IfTrueAction`, …): only `#Var#` is replaced when the option is read;
    /// escapes, nesting syntax and section variables are resolved once, when the action runs (see `Skin.execute`).
    public func actionOption(_ key: String) -> String {
        guard let raw = rawOption(key) else { return "" }
        return sectionContext.resolveStandardVariables(raw, in: self)
    }

    public func string(_ key: String, _ defaultValue: String = "") -> String {
        option(key) ?? defaultValue
    }

    /// Missing or empty → default; otherwise number/formula (unparseable → default).
    public func double(_ key: String, _ defaultValue: Double) -> Double {
        guard let s = option(key), !s.trimmingCharacters(in: .whitespaces).isEmpty else { return defaultValue }
        return OptionValue.number(s) ?? defaultValue
    }

    public func optionalDouble(_ key: String) -> Double? {
        guard let s = option(key), !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return OptionValue.number(s)
    }

    public func int(_ key: String, _ defaultValue: Int) -> Int {
        let d = double(key, Double(defaultValue))
        guard d.isFinite, abs(d) < Double(Int.max / 2) else { return defaultValue }
        return Int(d)
    }

    public func bool(_ key: String, _ defaultValue: Bool) -> Bool {
        guard let s = option(key), !s.trimmingCharacters(in: .whitespaces).isEmpty else { return defaultValue }
        return OptionValue.bool(s) ?? defaultValue
    }

    public func color(_ key: String, _ defaultValue: RGBA) -> RGBA {
        guard let s = option(key), !s.trimmingCharacters(in: .whitespaces).isEmpty else { return defaultValue }
        return OptionValue.color(s) ?? defaultValue
    }

    /// Numbered option family: `Key`, `Key2`, `Key3`… stopping at the first gap (after `Key2`).
    /// At most `limit` entries are read (guards against hostile skins).
    func numberedOptions(_ key: String, limit: Int = 1000) -> [(index: Int, value: String)] {
        var result: [(Int, String)] = []
        if let v = option(key) { result.append((1, v)) }
        var i = 2
        while i <= limit, let v = option("\(key)\(i)") {
            result.append((i, v))
            i += 1
        }
        return result
    }

    // MARK: Option reading

    /// Reads options common to every section. Subclasses override, call super, then read their own.
    open func readOptions() {
        dynamicVariables = bool("DynamicVariables", false)
        updateDivider = int("UpdateDivider", sectionContext.settings.defaultUpdateDivider)
        groups = OptionValue.list(string("Group")).map { $0.lowercased() }
    }

    /// Reads the options when they changed (`!SetOption`, load) or on every update for dynamic sections.
    ///
    /// Section variables in a section without DynamicVariables are resolved whenever its options are read, just not
    /// kept up to date: evidence from skins known to work in Rainmeter — HDD_Usage_Bars places hover rings with
    /// `X=[MeterDiskIcon:X]` (in its author's screenshot the next icon, at `X=134r` after the ring, is at X 135: the
    /// ring's X was the first icon's 1, not 0) and its three-drive variant would stack two icons otherwise;
    /// Mini Weather centers its temperature with `X=([Icon:X] + [Icon:W] / 2)`; HMNmeter2 puts its mouse regions on
    /// `[Button:X]`. The Dynamic Cheat Sheet adds that `!SetOption` makes its target "dynamic for one update". The
    /// load-time read cannot resolve them yet (no measure has a value and no meter a position), so a section whose
    /// options name a measure or meter is read once more when the first update reaches it — after the measures
    /// updated and the meters above it were placed (Mac timing; Rainmeter presumably resolves them at load).
    func readOptionsIfNeeded() {
        if needsOptionRead || dynamicVariables {
            sectionContext.assertOwned(#function)
            needsOptionRead = false
            readingAfterLoad = sectionContext.optionsLoaded
            defer { readingAfterLoad = false }
            readOptions()
        }
    }

    /// UpdateDivider bookkeeping: true on the first update and then every `updateDivider`-th update.
    /// A negative divider means "only the first update and explicit bangs" (manual: "If UpdateDivider=-1 or any
    /// negative number, then the measure is only updated once when the skin is loaded or refreshed"). 0 counts as 1.
    func consumeUpdateTick() -> Bool {
        defer { if updateTick < Int.max { updateTick += 1 } }
        if updateDivider < 0 { return updateTick == 0 }
        return updateTick % max(updateDivider, 1) == 0
    }

    public func isInGroup(_ group: String) -> Bool {
        groups.contains(group.trimmingCharacters(in: .whitespaces).lowercased())
    }

    // MARK: Mouse action states

    /// Current state of one mouse action (see `MouseActionState`).
    public func mouseActionState(_ kind: MouseEventKind) -> MouseActionState {
        mouseActionStates[kind] ?? .enabled
    }

    func setMouseActionState(_ kind: MouseEventKind, _ state: MouseActionState) {
        if state == .enabled {
            mouseActionStates[kind] = nil
        } else {
            mouseActionStates[kind] = state
            lastNonEnabledMouseState[kind] = state
        }
    }

    /// `!ToggleMouseAction`: between enabled and the last non-enabled state (disabled by default).
    func toggleMouseActionState(_ kind: MouseEventKind) {
        if mouseActionState(kind) == .enabled {
            setMouseActionState(kind, lastNonEnabledMouseState[kind] ?? .disabled)
        } else {
            setMouseActionState(kind, .enabled)
        }
    }
}
