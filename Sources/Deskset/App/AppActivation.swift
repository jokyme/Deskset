import AppKit

/// Deskset is a menu bar app (`.accessory`: no Dock icon, no menu bar of its own). While the skin editor or the
/// Settings window is open it becomes a regular app, so the editor has a Dock icon, ⌘-Tab and a menu bar with its
/// File / Edit / View menus (docs/editor-design.md §1); when the last of them closes it goes back to `.accessory`.
///
/// Windows are registered when shown (`track`); their closing is observed here. Headless runs (`--self-test`,
/// `--snapshot-ui`) use the `.prohibited` policy, which this never changes.
enum AppActivation {
    private static var windows: [WeakWindow] = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    private struct WeakWindow { weak var window: NSWindow? }

    /// Call when a skin editor or Settings window is about to be shown.
    static func track(_ window: NSWindow?) {
        guard let window else { return }
        let id = ObjectIdentifier(window)
        if observers[id] == nil {
            windows.append(WeakWindow(window: window))
            observers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                   object: window, queue: .main) { _ in
                untrack(id)
            }
        }
        apply(anyOpen: true)
    }

    private static func untrack(_ id: ObjectIdentifier) {
        if let token = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
        windows.removeAll { $0.window.map(ObjectIdentifier.init) == id || $0.window == nil }
        // `willClose` comes before the window is ordered out; decide once it is gone.
        DispatchQueue.main.async {
            apply(anyOpen: windows.contains { $0.window?.isVisible == true || $0.window?.isMiniaturized == true })
        }
    }

    /// The policy for the current one and whether a tracked window is open; nil = leave it.
    static func policy(current: NSApplication.ActivationPolicy, anyOpen: Bool) -> NSApplication.ActivationPolicy? {
        guard current != .prohibited else { return nil }
        let wanted: NSApplication.ActivationPolicy = anyOpen ? .regular : .accessory
        return wanted == current ? nil : wanted
    }

    private static func apply(anyOpen: Bool) {
        guard let policy = policy(current: NSApp.activationPolicy(), anyOpen: anyOpen) else { return }
        NSApp.setActivationPolicy(policy)
        // Becoming regular while already active does not bring up the menu bar until the app activates again.
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Tracked windows still open (self-tests).
    static var trackedCount: Int { windows.filter { $0.window != nil }.count }
}
