import AppKit
import DesksetCore

/// Main-only presentation of resolved menu values. The adapters qualify the source/session/epoch and keep
/// all expressions, runtime state and action transactions on their owner. No owner is waited on here.
final class DeskProgramMenus: NSObject, NSMenuDelegate {
    struct Request: Equatable, Hashable {
        let serial: UInt64
        fileprivate let presenter: UUID
    }
    typealias Tracking = (NSMenu, NSPoint, NSView) -> Bool

    private final class Opening {
        let request: Request
        let anchor: NSPoint
        weak var window: NSWindow?
        var menu: NSMenu?
        var onCancel: ((Request) -> Void)?
        var onSelect: ((ProgramMenuItemID) -> Void)?
        var items: [ObjectIdentifier: Item] = [:]

        init(request: Request, anchor: NSPoint, window: NSWindow, onCancel: @escaping (Request) -> Void) {
            self.request = request; self.anchor = anchor; self.window = window; self.onCancel = onCancel
        }
    }

    private enum Item {
        case program(ProgramMenuItemID, enabled: Bool)
        case native(NativeAction)
    }

    private final class NativeAction {
        let action: Selector
        weak var target: AnyObject?
        let hadTarget: Bool
        let enabled: Bool

        init(_ item: NSMenuItem, action: Selector) {
            self.action = action; target = item.target; hadTarget = item.target != nil; enabled = item.isEnabled
        }
    }

    private weak var view: NSView?
    private let presentsWindows: Bool
    private let trackMenu: Tracking?
    private let identity = UUID()
    private var serial: UInt64 = 0
    private var opening: Opening?
    private var tracking: [Opening] = []
    private(set) var isClosed = false
    var currentRequest: Request? { opening?.request }
    var menu: NSMenu? { opening?.menu }
    var isTracking: Bool { !tracking.isEmpty }

    /// A tracking hook receives the actual NSMenu without entering the user's modal tracking loop.
    /// With no hook, `presentsWindows: false` keeps the constructed menu until selection/cancel, for offscreen tests.
    init(view: NSView, presentsWindows: Bool = true, trackMenu: Tracking? = nil) {
        precondition(Thread.isMainThread)
        self.view = view; self.presentsWindows = presentsWindows; self.trackMenu = trackMenu
        super.init()
    }

    /// Capture the anchor before the adapter asynchronously asks its owner for a resolved snapshot.
    /// A newer request retires the previous opening, including a reply that has not arrived yet.
    func begin(at point: NSPoint, onCancel: @escaping (Request) -> Void = { _ in }) -> Request? {
        precondition(Thread.isMainThread)
        guard !isClosed else { return nil }
        cancel()
        // A cancellation callback may close this presenter or start a newer opening of its own.
        guard !isClosed, opening == nil, let window = eligibleWindow(at: point) else { return nil }
        let next = serial.addingReportingOverflow(1)
        guard !next.overflow else { close(); return nil }
        serial = next.partialValue
        let request = Request(serial: serial, presenter: identity)
        opening = Opening(request: request, anchor: point, window: window, onCancel: onCancel)
        return request
    }

    /// The list is already resolved and merged according to Core/adapter policy. Native items must be fresh
    /// (not members of another menu); represented objects remain intact. Original target/actions are wrapped
    /// and forwarded only after this request is consumed, just like a program item.
    func present(_ items: [ProgramMenuSnapshot.Node], for request: Request, nativeItems: [NSMenuItem] = [],
                 onSelect: @escaping (ProgramMenuItemID) -> Void) {
        precondition(Thread.isMainThread)
        guard !isClosed, let value = opening, value.request == request, value.menu == nil else { return }
        guard let view, let window = eligibleWindow(at: value.anchor), window === value.window,
              nativeItems.allSatisfy({ $0.menu == nil }),
              Set(nativeItems.map { ObjectIdentifier($0) }).count == nativeItems.count else {
            retire(value, cancelled: true); return
        }
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        menu.delegate = self
        value.menu = menu; value.onSelect = onSelect
        build(items, in: menu, opening: value)
        if !items.isEmpty && !nativeItems.isEmpty { menu.addItem(.separator()) }
        for item in nativeItems { menu.addItem(item) }
        prepareNative(nativeItems, opening: value)
        guard menu.numberOfItems > 0 else { retire(value, cancelled: true); return }
        guard opening === value, !isClosed, eligibleWindow(at: value.anchor) === window else {
            retire(value, cancelled: true); return
        }
        guard presentsWindows || trackMenu != nil else { return }

        tracking.append(value)
        if let trackMenu { _ = trackMenu(menu, value.anchor, view) }
        else { _ = menu.popUp(positioning: nil, at: value.anchor, in: view) }
        tracking.removeAll { $0 === value }
        // SDK: item actions are dispatched during normal menu tracking. Delegate close can precede or follow
        // that action, so only the tracking call's return retires an opening that still has no selection.
        retire(value, cancelled: true)
    }

    func cancel() {
        precondition(Thread.isMainThread)
        guard let value = opening else { return }
        retire(value, cancelled: true, stopTracking: true)
    }

    func close() {
        precondition(Thread.isMainThread)
        guard !isClosed else { return }
        isClosed = true
        cancel()
        // A selected action can close its parent reentrantly while the native tracking call is unwinding.
        for value in tracking { value.menu?.cancelTracking() }
    }

    func menuDidClose(_ menu: NSMenu) {
        precondition(Thread.isMainThread)
        // A close notification alone does not say whether AppKit is about to send a selected item's action.
        // Keep eligibility through tracking; present() performs unselected cleanup after tracking returns.
    }

    private func eligibleWindow(at point: NSPoint, requiringUnoccluded: Bool = true) -> NSWindow? {
        guard !isClosed, point.x.isFinite, point.y.isFinite, let view, let window = view.window,
              !view.isHiddenOrHasHiddenAncestor, view.visibleRect.contains(point) else { return nil }
        if presentsWindows {
            guard window.isVisible, !window.isMiniaturized, !window.ignoresMouseEvents else { return nil }
            // The menu can itself cover its parent after opening. The adapter still qualifies source facts;
            // presentation must not turn that native overlay into a new reason to discard a chosen item.
            if requiringUnoccluded, !window.occlusionState.contains(.visible) { return nil }
        }
        return window
    }

    private func build(_ nodes: [ProgramMenuSnapshot.Node], in menu: NSMenu, opening: Opening) {
        var pending = [(menu, nodes)]
        while let (parent, nodes) = pending.popLast() {
            for node in nodes {
                switch node {
                case .divider:
                    parent.addItem(.separator())
                case .submenu(let title, let children):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    let submenu = NSMenu(title: title)
                    submenu.autoenablesItems = false
                    item.submenu = submenu; parent.addItem(item)
                    pending.append((submenu, children))
                case .item(let id, let title, let checked, let enabled):
                    let item = NSMenuItem(title: title, action: #selector(chosen(_:)), keyEquivalent: "")
                    item.target = self; item.state = checked ? .on : .off; item.isEnabled = enabled
                    opening.items[ObjectIdentifier(item)] = .program(id, enabled: enabled)
                    parent.addItem(item)
                }
            }
        }
    }

    private func prepareNative(_ items: [NSMenuItem], opening: Opening) {
        var pending = items
        while let item = pending.popLast() {
            if let submenu = item.submenu {
                submenu.autoenablesItems = false
                pending.append(contentsOf: submenu.items)
            }
            guard !item.isSeparatorItem, let action = item.action else { continue }
            opening.items[ObjectIdentifier(item)] = .native(NativeAction(item, action: action))
            item.target = self; item.action = #selector(chosen(_:))
        }
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        precondition(Thread.isMainThread)
        guard !isClosed, let value = opening, let item = value.items[ObjectIdentifier(sender)], sender.isEnabled,
              let window = eligibleWindow(at: value.anchor, requiringUnoccluded: false), window === value.window else { return }
        switch item {
        case .program(let id, let enabled):
            guard enabled else { return }
            let selection = value.onSelect
            retire(value, cancelled: false)
            selection?(id)
        case .native(let action):
            let target = action.target
            guard action.enabled, !action.hadTarget || target != nil else { return }
            // Native actions leave the custom menu lease unused. Retire it before a possibly reentrant action.
            retire(value, cancelled: true)
            guard !isClosed, let window = eligibleWindow(at: value.anchor, requiringUnoccluded: false), window === value.window else { return }
            _ = NSApplication.shared.sendAction(action.action, to: target, from: sender)
        }
    }

    private func retire(_ value: Opening, cancelled: Bool, stopTracking: Bool = false) {
        guard opening === value else { return }
        opening = nil
        let cancellation = cancelled ? value.onCancel : nil
        value.onCancel = nil; value.onSelect = nil; value.items.removeAll()
        if stopTracking { value.menu?.cancelTracking() }
        cancellation?(value.request)
    }
}
