import Foundation
import DesksetCore

/// An open menu retains identities and resolved labels, never an opening runtime to replay later.
struct DeskProgramMenuSession {
    let id: UUID
    let sourceGeneration: UInt64
    let owners: [ElementID]
    let items: [ProgramMenuSnapshot.Node]
    private let enabledItems: Set<ProgramMenuItemID>

    init(id: UUID, snapshots: [ProgramMenuSnapshot]) {
        self.id = id
        sourceGeneration = snapshots.first?.sourceGeneration ?? 0
        owners = snapshots.map(\.owner)
        var items: [ProgramMenuSnapshot.Node] = [], enabled = Set<ProgramMenuItemID>()
        for snapshot in snapshots where !snapshot.items.isEmpty {
            if !items.isEmpty { items.append(.divider) }
            items += snapshot.items
            var pending = snapshot.items
            while let node = pending.popLast() {
                switch node {
                case .item(let id, _, _, let available): if available { enabled.insert(id) }
                case .submenu(_, let children): pending += children
                case .divider: break
                }
            }
        }
        self.items = items
        enabledItems = enabled
    }

    func allows(_ item: ProgramMenuItemID) -> Bool { enabledItems.contains(item) }
    func isAvailable(in runtime: ProgramRuntime) -> Bool { owners.allSatisfy(runtime.isMenuOwnerVisible) }

    /// Topmost local declaration (including an empty one), then the global widget menu once.
    /// The widget fallback also covers visible children that overflow a zero-area root.
    static func owners(root: ProgramElement, scene: WidgetScene, at point: SkinPoint) -> [ElementID] {
        guard point.x.isFinite, point.y.isFinite else { return [] }
        var result: [ElementID] = []
        if let local = scene.hitMap.entries.first(where: {
            $0.hasMenu && $0.elementID != root.id && scene.hitMap.isHit($0, x: point.x, y: point.y, images: nil)
        })?.elementID { result.append(local) }
        if root.menu != nil, scene.elements.contains(where: { $0.id == root.id && $0.visibility == .visible }) {
            result.append(root.id)
        }
        return result
    }
}
