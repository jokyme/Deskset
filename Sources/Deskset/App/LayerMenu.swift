import AppKit
import DesksetCore

/// The menus of layers and live data, shared by their rows in the sidebar and the canvas's right-click
/// (docs/editor-friendly.md §5.2 "Row context menu", §5.3 "Row menu", §9.7). The commands act on `names`, which become
/// the selection first when a command needs one (like a right-click in Finder). Hide and Lock never change the
/// selection; locks are editor state, never written to the file.
enum LayerMenu {
    /// The menu of layers: Hide · Lock — Duplicate · Delete · Arrange ▸ — Select All N … · Do Something When
    /// Clicked… — Show in Code. `run`: the menu of a run's row ("16 bars"), which adds "Show as Separate Rows".
    static func make(for names: [String], in editor: InspectorWindowController, run: Series? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let skin = editor.skin else { return menu }
        let meters = names.compactMap { skin.meter(named: $0) }
        guard !meters.isEmpty else { return menu }
        let layers = meters.map(\.name)
        func select(_ editor: InspectorWindowController) {
            if Set(editor.actionMeters.map { $0.lowercased() }) != Set(layers.map { $0.lowercased() }) {
                editor.canvasSelectionChanged(layers)
            }
        }

        // Hide when any is shown; Show when all are hidden. Lock when any is unlocked.
        let hide = meters.contains { !$0.hidden }
        menu.addItem(ClosureMenuItem(hide ? "Hide" : "Show", symbol: hide ? "eye.slash" : "eye") { [weak editor] in
            editor?.setLayersHidden(layers, hidden: hide)
        })
        let lock = !layers.allSatisfy(editor.isLayerLocked)
        menu.addItem(ClosureMenuItem(lock ? "Lock" : "Unlock", symbol: lock ? "lock" : "lock.open") { [weak editor] in
            editor?.setLayersLocked(layers, locked: lock)
        })
        menu.addItem(.separator())
        let duplicate = ClosureMenuItem("Duplicate", symbol: "plus.square.on.square") { [weak editor] in
            guard let editor else { return }
            select(editor)
            editor.duplicateSelection()
        }
        duplicate.keyEquivalent = "d"
        duplicate.keyEquivalentModifierMask = [.command]
        menu.addItem(duplicate)
        let sharedLayers = editor.sharedDeletionNote(layers)
        let delete = ClosureMenuItem("Delete", symbol: "trash", enabled: sharedLayers == nil) { [weak editor] in
            guard let editor else { return }
            select(editor)
            editor.deleteSelection()
        }
        delete.toolTip = sharedLayers
        delete.keyEquivalent = "\u{8}"
        delete.keyEquivalentModifierMask = []
        menu.addItem(delete)
        menu.addItem(arrangeItem(layers, in: editor))
        menu.addItem(.separator())
        if let others = selectAllItem(layers, in: editor) { menu.addItem(others) }
        menu.addItem(ClosureMenuItem("Do Something When Clicked…", symbol: "cursorarrow.click") { [weak editor] in
            editor?.showClickActions(for: layers)
        })
        if let run {
            let separate = editor.isShownSeparately(run)
            menu.addItem(ClosureMenuItem(separate ? "Show as One Row" : "Show as Separate Rows",
                                         symbol: separate ? "rectangle.compress.vertical" : "list.bullet.indent") { [weak editor] in
                editor?.setShownSeparately(run, !separate)
            })
        }
        menu.addItem(.separator())
        let location = skin.sources.location(section: layers[0])
        menu.addItem(ClosureMenuItem("Show in Code", symbol: "curlybraces", enabled: location != nil) { [weak editor] in
            editor?.showInCode(location)
        })
        return menu
    }

    /// Arrange ▸ Bring to Front ⇧⌘] · Bring Forward ⌘] · Send Backward ⌘[ · Send to Back ⇧⌘[.
    static func arrangeItem(_ layers: [String], in editor: InspectorWindowController) -> NSMenuItem {
        let item = NSMenuItem(title: "Arrange", action: nil, keyEquivalent: "")
        item.image = EditorStyle.image("square.3.layers.3d", size: 13)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let steps: [(String, InspectorWindowController.ArrangeStep, String, NSEvent.ModifierFlags)] = [
            ("Bring to Front", .front, "]", [.command, .shift]),
            ("Bring Forward", .forward, "]", [.command]),
            ("Send Backward", .backward, "[", [.command]),
            ("Send to Back", .back, "[", [.command, .shift]),
        ]
        for (title, step, key, modifiers) in steps {
            let possible: Bool
            if case .some = editor.arrangeTarget(layers, step) { possible = true } else { possible = false }
            let entry = ClosureMenuItem(title, enabled: possible) { [weak editor] in editor?.arrange(layers, step) }
            entry.keyEquivalent = key
            entry.keyEquivalentModifierMask = modifiers
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    /// "Select All 16 Bars" for a layer of a run; "Select All 5 Small Texts" for layers sharing a look.
    static func selectAllItem(_ layers: [String], in editor: InspectorWindowController) -> NSMenuItem? {
        guard let skin = editor.skin, let first = layers.first, let m = skin.meter(named: first) else { return nil }
        let catalog = editor.sidebar.catalog ?? LayerNaming.catalog(of: skin)
        var group: [String] = []
        var title = ""
        if let run = catalog.series(containing: first), run.kind == .layers,
           layers.allSatisfy({ run.contains($0) }), layers.count < run.members.count {
            group = run.members
            title = InspectorWindowController.titleCase(catalog.name(of: run)?.title ?? "\(run.members.count) layers")
        } else if let look = (m.rawOption("MeterStyle") ?? "").split(separator: "|").first
                    .map({ $0.trimmingCharacters(in: .whitespaces) }), !look.isEmpty {
            let users = InspectorWindowController.styleUsers(look, in: skin)
            guard users.count > layers.count, layers.allSatisfy({ l in users.contains { $0.caseInsensitiveCompare(l) == .orderedSame } })
            else { return nil }
            group = users
            let kinds = Set(users.compactMap { skin.meter(named: $0).map(LayerNaming.kindNoun) })
            let kind = kinds.count == 1 ? LayerNaming.kindPlural(kinds.first ?? "Layer") : "layers"
            var lookName = look
            if lookName.lowercased().hasPrefix("style"), lookName.count > 5 { lookName.removeFirst(5) }
            title = InspectorWindowController.titleCase("\(users.count) \(LayerNaming.humanized(lookName).lowercased()) \(kind)")
        } else {
            return nil
        }
        return ClosureMenuItem("Select All \(title)", symbol: "checklist") { [weak editor] in
            editor?.canvasSelectionChanged(group)
        }
    }

    /// The menu of live data: Show in a New Text Layer · Duplicate · Delete · Show in Code.
    static func makeData(for names: [String], in editor: InspectorWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let skin = editor.skin else { return menu }
        let data = names.compactMap { skin.measure(named: $0)?.name }
        guard let first = data.first else { return menu }
        if data.count == 1 {
            menu.addItem(ClosureMenuItem("Show in a New Text Layer", symbol: "textformat") { [weak editor] in
                editor?.showInNewTextLayer(first)
            })
            menu.addItem(ClosureMenuItem("Duplicate", symbol: "plus.square.on.square") { [weak editor] in
                editor?.duplicateData(data)
            })
        }
        // A parent's data goes with it: the command says so.
        let children = InspectorWindowController.dataChildren(of: data, in: skin).count
        let their = data.count == 1 ? "Its" : "Their"
        let shared = editor.sharedDeletionNote(data + InspectorWindowController.dataChildren(of: data, in: skin))
        let delete = ClosureMenuItem(children == 0 ? "Delete" : "Delete with \(their) \(children) Items", symbol: "trash",
                                     enabled: shared == nil) { [weak editor] in editor?.deleteData(data) }
        delete.toolTip = shared
        menu.addItem(delete)
        menu.addItem(.separator())
        let location = skin.sources.location(section: first)
        menu.addItem(ClosureMenuItem("Show in Code", symbol: "curlybraces", enabled: location != nil) { [weak editor] in
            editor?.showInCode(location)
        })
        return menu
    }
}
