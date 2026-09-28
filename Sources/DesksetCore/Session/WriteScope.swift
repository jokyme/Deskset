import Foundation

/// Where a change to one option of a part is written — what the Studio's scope sentence says before the change is
/// made ("This number only · Apply to All 4 Numbers"). The narrowest scope is the default; each wider one is one
/// explicit click.
///
/// In an INI widget:
/// - `.element`: the meter's own section in one of the widget's own files, so a value inherited from a style or a
///   variable is overridden for this part alone (nothing for a part only a shared file defines: `isLocal`);
/// - `.style`: the MeterStyle section the option comes from, for this widget (a style a shared file defines gets an
///   override block in the widget's own file, which wins because it is read after the include);
/// - `.sharedValue`: the variable the option is written as (`FontColor=#TextColor#`), for this widget;
/// - `.package`: the shared file (an `@Include` of the suite) that defines the style or the variable: this widget and
///   every other one that includes it.
public enum WriteScope: Equatable {
    case element
    case style(String)
    case sharedValue(String)
    case package(file: URL, section: String, key: String)

    public static func == (a: WriteScope, b: WriteScope) -> Bool {
        switch (a, b) {
        case (.element, .element): return true
        case (.style(let x), .style(let y)), (.sharedValue(let x), .sharedValue(let y)):
            return x.caseInsensitiveCompare(y) == .orderedSame
        case (.package(let f, let s, let k), .package(let g, let t, let l)):
            return SourceFileID(f) == SourceFileID(g) && s.caseInsensitiveCompare(t) == .orderedSame
                && k.caseInsensitiveCompare(l) == .orderedSame
        default: return false
        }
    }
}

/// One scope a change can take, with what it reaches.
public struct WriteScopeChoice: Equatable {
    public var scope: WriteScope
    /// The parts (meters) of this widget it changes, in file order.
    public var parts: [String]
    /// Of them, the ones that show now (a hidden part still changes, but the sentence counts what is seen).
    public var visibleParts: [String]
    /// `.package`: the widgets (configs) that read the shared file, this one included; else this widget alone.
    public var widgets: [String]
    /// The section the option is read from in this scope (the meter, the style, `Variables`, or the shared file's).
    public var section: String
    /// The key written (the option, or the variable's name).
    public var key: String

    public init(scope: WriteScope, parts: [String], visibleParts: [String], widgets: [String], section: String,
                key: String) {
        self.scope = scope
        self.parts = parts
        self.visibleParts = visibleParts
        self.widgets = widgets
        self.section = section
        self.key = key
    }
}

public enum WriteScopes {
    /// The scopes a change to `key` of the part `meter` can take, narrowest first: always `.element`; `.style` when the
    /// part takes the option from a MeterStyle; `.sharedValue` when the value is written as exactly one variable of the
    /// widget (never a built-in such as `#MACLABELCOLOR#`); `.package` when the style or variable is defined in a file
    /// other widgets share. A wider scope that reaches no more parts than the one before it is left out.
    public static func choices(meter: String, key: String, in skin: Skin) -> [WriteScopeChoice] {
        guard let m = skin.meter(named: meter) else { return [] }
        let name = m.name
        var result = [WriteScopeChoice(scope: .element, parts: [name], visibleParts: m.hidden ? [] : [name],
                                       widgets: [skin.config], section: name, key: key)]
        func visible(_ parts: [String]) -> [String] {
            parts.filter { skin.meter(named: $0).map { !$0.hidden } ?? false }
        }
        // The style the part takes the option from.
        var styleUsers: [String] = []
        var styleName: String?
        if case .style(let style, _)? = m.fileOrigin(key) {
            styleName = style
            styleUsers = users(ofStyle: style, key: key, in: skin)
            if styleUsers.count > 1 {
                result.append(WriteScopeChoice(scope: .style(style), parts: styleUsers, visibleParts: visible(styleUsers),
                                               widgets: [skin.config], section: style, key: key))
            }
        }
        // The variable the value is written as.
        var variable: String?
        var variableUsers: [String] = []
        if let v = soleVariable(m.fileOption(key)), !BuiltInVariables.isBuiltIn(v),
           skin.sources.location(section: "Variables", key: v) != nil {
            variable = v
            let usage = skin.valueUsages().variable(v)
            let sections = Set((usage?.sections ?? []).map { $0.lowercased() })
            variableUsers = skin.meters.filter { sections.contains($0.name.lowercased()) }.map(\.name)
            if variableUsers.count > max(styleUsers.count, 1) {
                result.append(WriteScopeChoice(scope: .sharedValue(v), parts: variableUsers,
                                               visibleParts: visible(variableUsers), widgets: [skin.config],
                                               section: "Variables", key: v))
            }
        }
        // The shared file defining the variable (preferred: it is what the suite shares) or the style.
        var shared: (file: URL, section: String, key: String, parts: [String])?
        if let v = variable, let file = skin.sharedDefinition(ofVariable: v) {
            shared = (file, "Variables", v, variableUsers)
        } else if let style = styleName, let file = skin.sharedDefinition(ofVariable: key, section: style) {
            shared = (file, style, key, styleUsers)
        }
        if let shared {
            let widgets = skin.configsIncluding(shared.file)
            if widgets.count > 1 {
                let parts = shared.parts.isEmpty ? [name] : shared.parts
                result.append(WriteScopeChoice(scope: .package(file: shared.file, section: shared.section,
                                                                key: shared.key),
                                               parts: parts, visibleParts: visible(parts), widgets: widgets,
                                               section: shared.section, key: shared.key))
            }
        }
        // A part only a shared file defines can't change for this widget alone (`isLocal`): its own section in that
        // file is where a change goes, for every widget that reads it.
        if !isLocal(meter: name, key: key, in: skin), !result.contains(where: { if case .package = $0.scope { return true }
                                                                                   return false }) {
            let file = skin.ownTarget(section: name, key: key).file
            let widgets = skin.configsIncluding(file)
            result.append(WriteScopeChoice(scope: .package(file: file, section: name, key: key), parts: [name],
                                           visibleParts: visible([name]), widgets: widgets.isEmpty ? [skin.config] : widgets,
                                           section: name, key: key))
        }
        return result
    }

    /// Whether `.element` can write `key` of the part `meter` for this widget alone: the part is defined in one of
    /// the widget's own files (`Skin.localTarget`). A part only a shared file (`@Resources`) defines is not — a
    /// block of its own here would move it in the drawing order — so `.element` writes nothing for it and the page
    /// offers the shared file's scope instead (the old Studio's rule: "comes from a shared file").
    public static func isLocal(meter: String, key: String, in skin: Skin) -> Bool {
        guard let m = skin.meter(named: meter) else { return false }
        return skin.localTarget(section: m.name, key: key) != nil
    }

    /// The meters that take `key` from the style `style` (their own files do not set it), in file order.
    public static func users(ofStyle style: String, key: String, in skin: Skin) -> [String] {
        skin.meters.filter { m in
            if case .style(let s, _)? = m.fileOrigin(key) { return s.caseInsensitiveCompare(style) == .orderedSame }
            return false
        }.map(\.name)
    }

    /// The scope a part's option is written with now: the narrowest (a new change starts there).
    public static func current(meter: String, key: String, in skin: Skin) -> WriteScopeChoice? {
        choices(meter: meter, key: key, in: skin).first
    }

    /// The edits that write `value` to `key` of the part `meter` with `scope` (none when the scope does not apply).
    public static func ops(_ scope: WriteScope, meter: String, key: String, value: String, in skin: Skin) -> [EditOp] {
        switch scope {
        case .element:
            // Never a shared file: a part only one defines has no scope of its own here (`isLocal`).
            guard let m = skin.meter(named: meter), let t = skin.localTarget(section: m.name, key: key) else { return [] }
            // Overriding a value an included file gives the section: after the block's @Include lines, so it wins.
            let overrides = !skin.isOwnFile(skin.ownTarget(section: m.name, key: key).file)
            return [.setValue(file: t.file, section: t.section, key: key, value: value, afterIncludes: overrides)]
        case .style(let style):
            let name = skin.styleSection(named: style)?.name ?? style
            guard let t = skin.localTarget(section: name, key: key) else { return [] }
            return [.setValue(file: t.file, section: t.section, key: key, value: value, afterIncludes: false)]
        case .sharedValue(let variable):
            guard let t = skin.localTarget(section: "Variables", key: variable) else { return [] }
            return [.setValue(file: t.file, section: t.section, key: variable, value: value, afterIncludes: true)]
        case .package(let file, let section, let packageKey):
            var ops: [EditOp] = [.setValue(file: file, section: section, key: packageKey, value: value,
                                           afterIncludes: false)]
            // This widget's own value for the same key would hide the shared one from it: it goes, so "all" is all.
            if let l = skin.sources.location(section: section, key: packageKey), skin.isOwnFile(l.file),
               SourceFileID(l.file) != SourceFileID(file) {
                ops.append(.removeKey(file: l.file, section: section, key: packageKey))
            }
            return ops
        }
    }

    /// The variable a value is written as when it is exactly one (`#TextColor#`, spaces around allowed); nil for
    /// anything else (`#A##B#`, `255,#Alpha#`, `[#Nested]`).
    public static func soleVariable(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.count > 2, t.hasPrefix("#"), t.hasSuffix("#") else { return nil }
        let inner = t.dropFirst().dropLast()
        guard !inner.isEmpty, !inner.contains("#"), !inner.contains("["), !inner.contains("]"),
              !inner.contains(where: \.isWhitespace), !inner.hasPrefix("*") else { return nil }
        return String(inner)
    }
}
