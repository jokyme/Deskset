/// The current dispatch owner of every documented bang. This table does not decide conversion eligibility:
/// commands such as WriteKeyValue and CommandMeasure still depend on their arguments and the target section.
package enum ActionCatalog {
    package enum HostKind: Equatable, Sendable {
        case window, lifecycle, group, ui, system
    }

    package enum Handler: Equatable, Sendable {
        case engineLocal
        case host(HostKind)
        case delayRunOnly
        case parserOnly
        case currentlyUnsupported
    }

    /// An engine-local entry always supplies its operand mapping; no raw local fallback exists.
    enum LocalOperation: Equatable, Sendable {
        case setOption(ActionSelection.Kind)
        case setVariable, writeKeyValue, update, redraw
        case updateMeter(ActionSelection.Kind)
        case updateMeasure(ActionSelection.Kind)
        case moveMeter
        case meterHidden(ActionStateChange, ActionSelection.Kind)
        case measureDisabled(ActionStateChange, ActionSelection.Kind)
        case measurePaused(ActionStateChange, ActionSelection.Kind)
        case commandMeasure, legacyPluginBang
        case mouseAction(ActionMouseOperation, ActionSelection.Kind)
        case log
    }

    enum Definition: Equatable, Sendable {
        case local(LocalOperation)
        case host(HostKind)
        case delayRunOnly, parserOnly, currentlyUnsupported
    }

    package struct Entry: Equatable, Sendable {
        package let name: String
        let definition: Definition

        package var handler: Handler {
            switch definition {
            case .local: return .engineLocal
            case .host(let kind): return .host(kind)
            case .delayRunOnly: return .delayRunOnly
            case .parserOnly: return .parserOnly
            case .currentlyUnsupported: return .currentlyUnsupported
            }
        }
    }

    package static let all: [Entry] = makeEntries()

    /// Exact-name lookup. ActionParser normalizes action text; direct Bang callers retain their existing behavior.
    package static func handler(for name: String) -> Handler? { byName[name]?.handler }

    static func definition(for name: String) -> Definition? { byName[name]?.definition }

    private static let byName: [String: Entry] = {
        var result: [String: Entry] = [:]
        for entry in all { result[entry.name] = entry }
        return result
    }()

    private static func makeEntries() -> [Entry] {
        var entries: [Entry] = []
        func add(_ names: [String], _ definition: Definition) {
            entries.append(contentsOf: names.map { Entry(name: $0, definition: definition) })
        }

        add(["setoption"], .local(.setOption(.name)))
        add(["setoptiongroup"], .local(.setOption(.group)))
        add(["setvariable"], .local(.setVariable))
        add(["writekeyvalue"], .local(.writeKeyValue))
        add(["update"], .local(.update))
        add(["redraw"], .local(.redraw))
        add(["updatemeter"], .local(.updateMeter(.name)))
        add(["updatemetergroup"], .local(.updateMeter(.group)))
        add(["updatemeasure"], .local(.updateMeasure(.name)))
        add(["updatemeasuregroup"], .local(.updateMeasure(.group)))
        add(["movemeter"], .local(.moveMeter))
        add(["showmeter"], .local(.meterHidden(.set(false), .name)))
        add(["hidemeter"], .local(.meterHidden(.set(true), .name)))
        add(["togglemeter"], .local(.meterHidden(.toggle, .name)))
        add(["showmetergroup"], .local(.meterHidden(.set(false), .group)))
        add(["hidemetergroup"], .local(.meterHidden(.set(true), .group)))
        add(["togglemetergroup"], .local(.meterHidden(.toggle, .group)))
        add(["enablemeasure"], .local(.measureDisabled(.set(false), .name)))
        add(["disablemeasure"], .local(.measureDisabled(.set(true), .name)))
        add(["togglemeasure"], .local(.measureDisabled(.toggle, .name)))
        add(["enablemeasuregroup"], .local(.measureDisabled(.set(false), .group)))
        add(["disablemeasuregroup"], .local(.measureDisabled(.set(true), .group)))
        add(["togglemeasuregroup"], .local(.measureDisabled(.toggle, .group)))
        add(["pausemeasure"], .local(.measurePaused(.set(true), .name)))
        add(["unpausemeasure"], .local(.measurePaused(.set(false), .name)))
        add(["togglepausemeasure"], .local(.measurePaused(.toggle, .name)))
        add(["pausemeasuregroup"], .local(.measurePaused(.set(true), .group)))
        add(["unpausemeasuregroup"], .local(.measurePaused(.set(false), .group)))
        add(["togglepausemeasuregroup"], .local(.measurePaused(.toggle, .group)))
        add(["commandmeasure"], .local(.commandMeasure))
        add(["pluginbang"], .local(.legacyPluginBang))
        add(["disablemouseaction"], .local(.mouseAction(.disable, .name)))
        add(["clearmouseaction"], .local(.mouseAction(.clear, .name)))
        add(["enablemouseaction"], .local(.mouseAction(.enable, .name)))
        add(["togglemouseaction"], .local(.mouseAction(.toggle, .name)))
        add(["disablemouseactiongroup"], .local(.mouseAction(.disable, .group)))
        add(["clearmouseactiongroup"], .local(.mouseAction(.clear, .group)))
        add(["enablemouseactiongroup"], .local(.mouseAction(.enable, .group)))
        add(["togglemouseactiongroup"], .local(.mouseAction(.toggle, .group)))
        add(["log"], .local(.log))

        add([
            "refresh", "refreshapp", "refreshgroup", "activateconfig", "deactivateconfig",
            "deactivateconfiggroup", "toggleconfig", "quit"
        ], .host(.lifecycle))
        add([
            "disablemouseactionskingroup", "clearmouseactionskingroup", "enablemouseactionskingroup",
            "togglemouseactionskingroup", "updategroup", "redrawgroup", "setvariablegroup"
        ], .host(.group))
        add([
            "move", "setwindowposition", "zpos", "zposgroup", "settransparency", "settransparencygroup",
            "draggable", "draggablegroup", "clickthrough", "clickthroughgroup", "keeponscreen",
            "keeponscreengroup", "snapedges", "snapedgesgroup", "autoselectscreen", "autoselectscreengroup",
            "show", "hide", "toggle", "showfade", "hidefade", "togglefade", "showgroup", "hidegroup",
            "togglegroup", "showfadegroup", "hidefadegroup", "togglefadegroup", "fadeduration",
            "fadedurationgroup"
        ], .host(.window))
        add([
            "skinmenu", "skincustommenu", "traymenu", "manage", "about", "editskin"
        ], .host(.ui))
        add([
            "setclip", "setwallpaper", "play", "playloop", "playstop"
        ], .host(.system))

        add([
            "delay"
        ], .delayRunOnly)
        add([
            "execute"
        ], .parserOnly)
        add([
            "resetstats", "loadlayout", "showblur", "hideblur", "toggleblur", "addblur", "removeblur",
            "setanchor"
        ], .currentlyUnsupported)
        return entries
    }
}
