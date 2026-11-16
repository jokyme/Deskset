import AppKit

/// Application interface theme (`UITheme=0|1|2` in `Rainmeter.ini`): controls utility windows, menus and tooltips
/// without overriding `NSApp.appearance` or changing skin windows' system-appearance tracking.
enum AppUITheme: Int, CaseIterable, Equatable {
    case auto = 0
    case light = 1
    case dark = 2

    var title: String {
        switch self {
        case .auto: return L("Auto")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Applies `UITheme` to Deskset's host windows, menus and tooltips while leaving desktop skin windows on the macOS
/// system appearance. Must be called on the main thread.
enum AppTheme {
    private struct Entry {
        weak var window: NSWindow?
        weak var app: AppController?
    }

    private static var entries: [Entry] = []

    /// Registers a utility window owned by `app` and applies its current `UITheme`.
    static func register(_ window: NSWindow?, app: AppController) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let window else { return }
        prune()
        if !entries.contains(where: { $0.window === window && $0.app === app }) {
            entries.append(Entry(window: window, app: app))
        }
        apply(app.state.uiTheme, to: window)
    }

    /// Re-applies `app`'s current `UITheme` to all registered utility windows belonging to `app`.
    static func applyAll(for app: AppController) {
        dispatchPrecondition(condition: .onQueue(.main))
        prune()
        let theme = app.state.uiTheme
        for entry in entries where entry.app === app {
            apply(theme, to: entry.window)
        }
        apply(theme, to: app.skinToolTips.panelForTheme)
    }

    static func apply(_ theme: AppUITheme, to window: NSWindow?) {
        window?.appearance = theme.nsAppearance
    }

    static func apply(_ theme: AppUITheme, to menu: NSMenu?) {
        menu?.appearance = theme.nsAppearance
    }

    private static func prune() {
        entries.removeAll { $0.window == nil || $0.app == nil }
    }
}
