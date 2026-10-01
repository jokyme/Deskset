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

    package struct Entry: Equatable, Sendable {
        package let name: String
        package let handler: Handler
    }

    package static let all: [Entry] = makeEntries()

    /// Exact-name lookup. ActionParser normalizes action text; direct Bang callers retain their existing behavior.
    package static func handler(for name: String) -> Handler? { byName[name] }

    private static let byName: [String: Handler] = {
        var result: [String: Handler] = [:]
        for entry in all { result[entry.name] = entry.handler }
        return result
    }()

    private static func makeEntries() -> [Entry] {
        var entries: [Entry] = []
        func add(_ names: [String], _ handler: Handler) {
            entries.append(contentsOf: names.map { Entry(name: $0, handler: handler) })
        }

        add([
            "setoption", "setoptiongroup", "setvariable", "writekeyvalue", "update", "redraw", "updatemeter",
            "updatemetergroup", "updatemeasure", "updatemeasuregroup", "movemeter", "showmeter", "hidemeter",
            "togglemeter", "showmetergroup", "hidemetergroup", "togglemetergroup", "enablemeasure",
            "disablemeasure", "togglemeasure", "enablemeasuregroup", "disablemeasuregroup",
            "togglemeasuregroup", "pausemeasure", "unpausemeasure", "togglepausemeasure", "pausemeasuregroup",
            "unpausemeasuregroup", "togglepausemeasuregroup", "commandmeasure", "pluginbang",
            "disablemouseaction", "clearmouseaction", "enablemouseaction", "togglemouseaction",
            "disablemouseactiongroup", "clearmouseactiongroup", "enablemouseactiongroup",
            "togglemouseactiongroup", "log"
        ], .engineLocal)

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
