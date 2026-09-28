import AppKit
import DesksetCore

// The layer list following a step in place (design §9.5): when the rows are the same ones — the same sections, runs,
// names, kinds and order — the list keeps its rows (no `reloadData`, which makes every row's views again and lays the
// list out) and only the rows whose name, second line, state or picture changed follow.

extension InspectorWindowController {
    /// What a row of the Layers tab shows that a step can change (besides its picture).
    struct LayerRowLook: Equatable {
        var display: String
        var subtitle: String
        var symbol: String?
        var isLocked: Bool
        var isCutOff: Bool
        var hidden: Bool

        init(_ item: Item, skin: Skin) {
            display = item.display
            subtitle = item.subtitle
            symbol = item.symbol
            isLocked = item.isLocked
            isCutOff = item.isCutOff
            let meters = (item.seriesMembers ?? (item.kind == .meter ? [item.title] : [])).compactMap { skin.meter(named: $0) }
            hidden = !meters.isEmpty && meters.allSatisfy(\.hidden)
        }
    }

    /// `rebuildSidebar` made its items again (`allItems`, from `previous`): when the Layers tab shows the same rows,
    /// the items it shows take the new names and states and only the rows that changed are made again. Returns false
    /// when the list must be loaded again (`reloadList`).
    func followListInPlace(previous: [Item], skin: Skin) -> Bool {
        let state = inPlace
        defer { state.listSkin = skin }
        guard InspectorInPlace.isEnabled, state.listSkin === skin, sidebarTab == .layers,
              sidebar.rowLimit == nil, sidebar.pendingRowLimit == nil, !listItems.isEmpty,
              previous.count == allItems.count,
              zip(previous, allItems).allSatisfy({ a, b in
                  a.title == b.title && a.kind == b.kind && a.detail == b.detail && a.isSkin == b.isSkin
              }) else { return false }
        // The rows before: what each showed.
        var before: [ObjectIdentifier: LayerRowLook] = [:]
        func note(_ items: [Item]) {
            for item in items {
                before[ObjectIdentifier(item)] = LayerRowLook(item, skin: skin)
                note(item.children)
            }
        }
        note(listItems)
        // The shown items take the new ones' names and states; the list is made from them again.
        let fresh = allItems
        for (old, new) in zip(previous, fresh) { Self.take(new, into: old) }
        allItems = previous
        let rows = layerRows()
        guard Self.sameRows(listItems, rows) else { return false }
        func carry(_ olds: [Item], _ news: [Item]) {
            for (old, new) in zip(olds, news) {
                if old !== new { Self.take(new, into: old) }
                carry(old.children, new.children)
            }
        }
        carry(listItems, rows)
        // Rows whose words or state changed are made again; the others take their new picture.
        var changed = IndexSet()
        let visible = outline.rows(in: outline.visibleRect)
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? Item, !item.isGroup else { continue }
            let look = LayerRowLook(item, skin: skin)
            if before[ObjectIdentifier(item)] != look {
                changed.insert(row)
                continue
            }
            guard visible.contains(row), let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCell
            else { continue }
            // Hidden is the running skin's, which the step already changed: the cell says what it showed.
            if item.kind == .meter, !item.isSkin, cell.isLayerHidden != look.hidden {
                changed.insert(row)
                continue
            }
            let picture: NSImage?
            if item.isSkin {
                picture = sidebar.thumbnails.widgetThumbnail(of: skin, panel: panelColor(for: skin), dark: isSidebarDark)
            } else if item.kind == .meter {
                picture = thumbnail(for: item, meters: (item.seriesMembers ?? [item.title]).compactMap { skin.meter(named: $0) },
                                    skin: skin)
            } else {
                continue
            }
            if cell.thumbnail.image !== picture { cell.thumbnail.image = picture }
        }
        if !changed.isEmpty {
            clearListHover()
            outline.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            restoreListHover()
        }
        state.listUpdates += 1
        syncOutlineSelection()
        updateEmptyState()
        return true
    }

    /// Whether two lists have the same rows: the same sections, runs and captions, in the same order.
    static func sameRows(_ a: [Item], _ b: [Item]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            x.title == y.title && x.kind == y.kind && x.isSkin == y.isSkin && x.detail == y.detail
                && x.seriesMembers == y.seriesMembers && x.display == y.display && sameRows(x.children, y.children)
        }
    }

    /// An item shown takes what a new one for the same row says.
    static func take(_ new: Item, into old: Item) {
        old.display = new.display
        old.subtitle = new.subtitle
        old.symbol = new.symbol
        old.isLocked = new.isLocked
        old.isCutOff = new.isCutOff
    }
}
