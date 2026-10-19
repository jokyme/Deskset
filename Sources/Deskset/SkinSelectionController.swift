import AppKit
import DesksetCore

/// Selection is transient. Its settings remain editable in memory, while AppState defers writing selected configs
/// until they are deselected. Screen geometry here uses AppKit points; the edge target widths use physical pixels.
final class SkinSelectionController {
    unowned let app: AppController
    private var selected: Set<String> = []
    private var source: PointerEventSource?
    private var monitor: AnyObject?
    private var gesture: Gesture?
    private var generation = 0
    private var zoomGenerations: [String: Int] = [:]
    private var menuTracking = 0

    init(app: AppController) {
        self.app = app
        source = app.presentsWindows ? SystemPointerEventSource() : nil
    }

    deinit { if let monitor { source?.stopWatching(monitor) } }

    var selectedConfigs: [String] { controllers.map(\.config) }
    private var controllers: [SkinWindowController] {
        app.sortedControllers.filter { contains($0.config) && !$0.isStopped }
    }
    func contains(_ config: String) -> Bool { selected.contains(config.lowercased()) }
    static func isSelectionGesture(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains([.control, .option])
    }

    private var draggingDisabled: Bool {
        let raw = app.state.data.rainmeterOptions.first {
            $0.key.caseInsensitiveCompare("DisableDragging") == .orderedSame
        }?.value
        return raw.flatMap(Int.init).map { $0 != 0 } ?? false
    }

    func toggle(_ c: SkinWindowController) {
        guard !c.isStopped else { return }
        if contains(c.config) { remove(c); return }
        endDrag()
        let groups = Set(c.runtime.snapshot.dragGroups)
        let targets = app.sortedControllers.filter {
            $0 === c || !groups.isDisjoint(with: $0.runtime.snapshot.dragGroups)
        }
        for target in targets where !target.isStopped && !contains(target.config) {
            target.view.cancelInteractionForSelection()
            guard !target.isStopped else { continue }
            selected.insert(target.config.lowercased())
            app.state.beginSkinSelection(target.config)
            target.selectionDidChange()
        }
        updateMonitor()
        if app.presentsWindows {
            c.window.makeKey()
            c.window.makeFirstResponder(c.view)
        }
        app.notifyChanged()
    }

    func remove(_ c: SkinWindowController) {
        guard contains(c.config) else { return }
        endDrag()
        selected.remove(c.config.lowercased())
        app.state.endSkinSelection(c.config)
        c.selectionDidChange()
        updateMonitor()
        app.notifyChanged()
    }

    func clear() {
        guard !selected.isEmpty else { return }
        endDrag()
        let old = controllers
        let names = selected
        selected.removeAll()
        for name in names { app.state.endSkinSelection(name) }
        for c in old { c.selectionDidChange() }
        updateMonitor()
        app.notifyChanged()
    }

    /// A focus transfer to another selected skin keeps the selection. Defer until AppKit has installed its new key
    /// window; a menu does not replace that window. Modifier input is injectable for the headless checks.
    static var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    func focusDidChange(from c: SkinWindowController) {
        guard contains(c.config), !Self.isSelectionGesture(Self.modifierFlags()) else { return }
        app.later { app in
            let selection = app.skinSelection
            guard !Self.isSelectionGesture(Self.modifierFlags()),
                  !selection.controllers.contains(where: { $0.window === NSApp.keyWindow }) else { return }
            selection.clear()
        }
    }

    /// Watch outside presses only while there is a selection. No keyboard monitor or accessibility permission.
    private func updateMonitor() {
        if selected.isEmpty {
            if let monitor { source?.stopWatching(monitor) }
            monitor = nil
        } else if monitor == nil, let source {
            monitor = source.startWatching(global: [.leftMouseDown, .rightMouseDown],
                                            local: [.leftMouseDown, .rightMouseDown]) { [weak self] event, local in
                self?.outsidePress(event, local: local)
            }
        }
    }

    func outsidePress(_ event: NSEvent, local: Bool) {
        guard !Self.isSelectionGesture(event.modifierFlags) else { return }
        if local && menuTracking > 0 { return }
        if local, controllers.contains(where: { $0.window === event.window }) { return }
        clear()
    }

    func beginMenuTracking() { menuTracking += 1 }
    func endMenuTracking() { menuTracking = max(0, menuTracking - 1) }

    func use(_ source: PointerEventSource?) {
        if let monitor { self.source?.stopWatching(monitor) }
        monitor = nil
        self.source = source
        updateMonitor()
    }

    func color(for c: SkinWindowController) -> RGBA {
        if let color = c.runtime.snapshot.selectedColor { return color }
        let raw = app.state.data.rainmeterOptions.first {
            $0.key.caseInsensitiveCompare("SelectedColor") == .orderedSame
        }?.value
        return raw.flatMap(OptionValue.color) ?? RGBA(r: 173, g: 216, b: 230, a: 90)
    }

    struct Edge: OptionSet {
        let rawValue: Int
        static let left = Edge(rawValue: 1)
        static let right = Edge(rawValue: 2)
        static let top = Edge(rawValue: 4)
        static let bottom = Edge(rawValue: 8)
        var horizontal: Bool { !intersection([.left, .right]).isEmpty }
        var vertical: Bool { !intersection([.top, .bottom]).isEmpty }
    }

    /// Corners extend along the edge, not into a filled 20 × 20 square. This also keeps tiny windows reachable.
    static func edge(at point: NSPoint, size: NSSize, backingScale: CGFloat) -> Edge {
        guard size.width > 0, size.height > 0, CGRect(origin: .zero, size: size).contains(point) else { return [] }
        let pixel = 1 / max(1, backingScale)
        let horizontal: Edge = point.x <= (size.width - pixel) / 2 ? .left : .right
        let vertical: Edge = point.y <= (size.height - pixel) / 2 ? .top : .bottom
        let x = max(0, min(point.x, size.width - pixel - point.x))
        let y = max(0, min(point.y, size.height - pixel - point.y))
        let edgeX = min(10 * pixel, max(pixel, size.width / 2))
        let edgeY = min(10 * pixel, max(pixel, size.height / 2))
        guard x < edgeX || y < edgeY else { return [] }
        if x < min(20 * pixel, max(pixel, size.width / 2)),
           y < min(20 * pixel, max(pixel, size.height / 2)) { return horizontal.union(vertical) }
        return x < edgeX ? horizontal : vertical
    }

    func edge(for c: SkinWindowController, point: NSPoint) -> Edge {
        guard contains(c.config), !draggingDisabled, c.facts.settings.effectiveDraggable else { return [] }
        return Self.edge(at: point, size: c.view.bounds.size, backingScale: c.window.backingScaleFactor)
    }

    func cursor(for c: SkinWindowController, point: NSPoint) -> NSCursor {
        let edge = edge(for: c, point: point)
        if edge.horizontal && edge.vertical {
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: edge == [.left, .top] || edge == [.right, .bottom]
                    ? .topLeft : .topRight, directions: .all)
            }
            return .crosshair
        }
        if edge.horizontal { return .resizeLeftRight }
        if edge.vertical { return .resizeUpDown }
        return .arrow
    }

    private struct Entry {
        var controller: SkinWindowController
        var frame: NSRect
        var percent: Int
    }
    private struct Gesture {
        var source: SkinWindowController
        var entries: [Entry]
        var start: NSPoint
        var edge: Edge
        var axisHorizontal: Bool?
        var moved = false
        var percentDelta = 0
        var positionChanged = false
        var appliedZoom = false
        var generation: Int
    }

    func beginDrag(_ c: SkinWindowController, point: NSPoint, screen: NSPoint) {
        guard contains(c.config), !draggingDisabled, c.facts.settings.effectiveDraggable else { return }
        endDrag()
        generation += 1
        let entries = controllers.map {
            Entry(controller: $0, frame: $0.window.frame, percent: Int(($0.effectiveZoomFactor * 100).rounded()))
        }
        gesture = Gesture(source: c, entries: entries, start: screen,
                          edge: edge(for: c, point: point), generation: generation)
        for entry in entries {
            zoomGenerations[entry.controller.config.lowercased()] = generation
            entry.controller.beginDragPress()
        }
    }

    func drag(to screen: NSPoint, flags: NSEvent.ModifierFlags) {
        guard var current = gesture, !current.source.isStopped,
              let primary = current.entries.first(where: { $0.controller === current.source }) else { return }
        let dx = screen.x - current.start.x, dy = screen.y - current.start.y
        let pixel = 1 / max(1, current.source.window.backingScaleFactor)
        guard current.moved || abs(dx) >= 2 * pixel || abs(dy) >= 2 * pixel else { return }
        current.moved = true
        if current.edge.isEmpty {
            var translation = NSPoint(x: dx, y: dy)
            if current.source.state.snapEdges && !flags.contains(.control) && !flags.contains(.shift) {
                let proposed = primary.frame.offsetBy(dx: dx, dy: dy)
                let others = app.sortedControllers.filter { !contains($0.config) && $0.isShown }.map(\.window.frame)
                let snapped = WindowGeometry.snapped(proposed, screens: EnvironmentStore.shared.currentScreens,
                                                      others: others)
                translation.x += snapped.minX - proposed.minX
                translation.y += snapped.minY - proposed.minY
            }
            for entry in current.entries where !entry.controller.isStopped {
                entry.controller.window.setFrameOrigin(NSPoint(x: entry.frame.minX + translation.x,
                                                               y: entry.frame.minY + translation.y))
            }
            current.positionChanged = translation != .zero
        } else if !app.state.forceDefaultZoom {
            current.appliedZoom = true
            if current.axisHorizontal == nil {
                current.axisHorizontal = current.edge.horizontal && (!current.edge.vertical
                    || abs(dx) / max(1, primary.frame.width) >= abs(dy) / max(1, primary.frame.height))
            }
            let horizontal = current.axisHorizontal == true
            let size = horizontal ? primary.frame.width : primary.frame.height
            let difference = horizontal ? (current.edge.contains(.left) ? -dx : dx)
                : (current.edge.contains(.top) ? dy : -dy)
            let percent = min(500, max(10, Int((Double(primary.percent) * max(pixel, size + difference)
                / max(pixel, size)).rounded())))
            current.percentDelta = percent - primary.percent
            let newSize = SkinRuntime.scaledWindowSize(width: current.source.runtime.snapshot.logicalSize.width,
                                                       height: current.source.runtime.snapshot.logicalSize.height,
                                                       zoomFactor: Double(percent) / 100)
            // Rainmeter 5.0 RC1 moves all selected windows by the primary window's size change on the left/top
            // axes. Right/bottom drags leave their top-left positions unchanged.
            let shift = NSPoint(x: current.edge.contains(.left) ? newSize.width - primary.frame.width : 0,
                                y: current.edge.contains(.top) ? primary.frame.height - newSize.height : 0)
            current.positionChanged = shift != .zero
            for entry in current.entries where !entry.controller.isStopped {
                let c = entry.controller
                zoomGenerations[c.config.lowercased()] = current.generation
                c.zoomPositionOverride = NSPoint(x: entry.frame.minX + shift.x, y: entry.frame.maxY + shift.y)
                c.requestZoom(percent: min(500, max(10, entry.percent + current.percentDelta)))
            }
        }
        gesture = current
    }

    func endDrag() {
        guard let current = gesture else { return }
        gesture = nil
        for entry in current.entries where !entry.controller.isStopped {
            let c = entry.controller
            if !current.appliedZoom {
                c.endDragPress(moved: current.positionChanged)
                c.zoomPositionOverride = nil
                zoomGenerations[c.config.lowercased()] = nil
                continue
            }
            let key = c.config.lowercased()
            c.requestZoom(percent: min(500, max(10, entry.percent + current.percentDelta))) { [weak self, weak c] in
                guard let self, let c, !c.isStopped, self.zoomGenerations[key] == current.generation else { return }
                c.endDragPress(moved: current.moved, savePosition: current.positionChanged)
                c.zoomPositionOverride = nil
                self.zoomGenerations[key] = nil
            }
        }
    }

    @discardableResult
    func keyDown(_ event: NSEvent) -> Bool {
        guard !selected.isEmpty else { return false }
        let step: CGFloat = event.modifierFlags.contains(.control) ? 10 : 1
        let offset: NSPoint
        switch event.keyCode {
        case 123: offset = NSPoint(x: -step, y: 0)
        case 124: offset = NSPoint(x: step, y: 0)
        case 125: offset = NSPoint(x: 0, y: -step)
        case 126: offset = NSPoint(x: 0, y: step)
        default: return true
        }
        guard !draggingDisabled else { return true }
        for c in controllers {
            c.window.setFrameOrigin(NSPoint(x: c.window.frame.minX + offset.x, y: c.window.frame.minY + offset.y))
            c.windowMoved()
        }
        return true
    }
}
