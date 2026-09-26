import AppKit

/// Window placement, stacking and visibility rules for skin windows, kept free of window objects so they can be
/// checked by `Deskset --self-test`.
///
/// Manual references: https://docs.rainmeter.net/manual/settings/skin-sections/ (AlwaysOnTop, KeepOnScreen,
/// SnapEdges, AlphaValue, OnHover, FadeDuration) and https://docs.rainmeter.net/manual/arranging-skins/.
enum WindowGeometry {
    /// "skins snap when dragged within 10 pixels of other skins or screen edges".
    static let snapThreshold: CGFloat = 10

    struct Screen: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    static func currentScreens() -> [Screen] {
        NSScreen.screens.map { Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    /// Height of the primary screen (the one with the menu bar, `NSScreen.screens[0]`, origin 0,0). Skin positions
    /// are stored with a top-left origin at the primary screen's top-left corner, like Rainmeter's WindowX/WindowY.
    static func primaryHeight(_ screens: [Screen]) -> CGFloat {
        screens.first?.frame.height ?? 900
    }

    // MARK: Coordinates

    /// Cocoa frame (bottom-left origin) for a top-left position.
    static func frame(topLeftX x: Double, y: Double, size: CGSize, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: CGFloat(x), y: primaryHeight - CGFloat(y) - size.height, width: size.width, height: size.height)
    }

    /// Top-left position of a Cocoa frame.
    static func topLeft(of frame: CGRect, primaryHeight: CGFloat) -> (x: Double, y: Double) {
        (Double(frame.minX), Double(primaryHeight - frame.maxY))
    }

    /// Position for a skin without a saved position: cascaded from the top-left of the visible area.
    static func cascadeFrame(index: Int, size: CGSize, visible: CGRect) -> CGRect {
        let step = CGFloat(min(max(index, 0), 20) * 30)
        return CGRect(x: visible.minX + 60 + step, y: visible.maxY - 60 - step - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Keep on screen

    /// Where a skin may be on one screen: the whole screen except the menu bar strip at the top (a desktop-level
    /// window there would be covered by the menu bar). The Dock area is allowed: it may be hidden.
    static func keepArea(_ s: Screen) -> CGRect {
        let top = min(s.frame.maxY, max(s.visibleFrame.maxY, s.frame.minY))
        return CGRect(x: s.frame.minX, y: s.frame.minY, width: s.frame.width, height: max(top - s.frame.minY, 0))
    }

    /// The screen a window belongs to: the one it overlaps most, else the nearest one.
    static func screenIndex(for frame: CGRect, screens: [Screen]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best: (index: Int, area: CGFloat)?
        for (i, s) in screens.enumerated() {
            let overlap = s.frame.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (i, area) }
        }
        if let best, best.area > 0 { return best.index }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.indices.min { distance(center, to: screens[$0].frame) < distance(center, to: screens[$1].frame) }
    }

    private static func distance(_ p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// KeepOnScreen: "Skins can move between monitors but won't bridge them" — the frame is moved fully inside the
    /// screen it overlaps most. A skin larger than the screen keeps its top-left corner visible.
    static func keptOnScreen(_ frame: CGRect, screens: [Screen]) -> CGRect {
        guard let i = screenIndex(for: frame, screens: screens) else { return frame }
        return clamp(frame, into: keepArea(screens[i]))
    }

    static func clamp(_ frame: CGRect, into area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return frame }
        var f = frame
        f.origin.x = min(max(f.minX, area.minX), max(area.maxX - f.width, area.minX))
        // y grows upward: keep the top edge inside first (maxY ≤ area.maxY), then the bottom when there is room.
        f.origin.y = max(min(f.minY, area.maxY - f.height), area.minY)
        if f.maxY > area.maxY { f.origin.y = area.maxY - f.height }
        return f
    }

    /// True when no part of the frame is on any screen.
    static func isOffScreen(_ frame: CGRect, screens: [Screen]) -> Bool {
        !screens.contains { $0.frame.intersects(frame) }
    }

    /// Even with KeepOnScreen off, a skin that ended up entirely off every screen (a display was disconnected, or a
    /// saved position from another setup) is brought back onto the nearest one — otherwise it would be unreachable.
    static func rescuedIfOffScreen(_ frame: CGRect, screens: [Screen]) -> CGRect {
        isOffScreen(frame, screens: screens) ? keptOnScreen(frame, screens: screens) : frame
    }

    // MARK: Snapping

    /// SnapEdges: moves the frame onto a nearby screen edge (full and visible frames) or another skin's edge when
    /// within `threshold`. Other skins only count when they are close along the other axis, so a skin does not jump
    /// to the invisible extension of a far-away skin's edge.
    static func snapped(_ frame: CGRect, screens: [Screen], others: [CGRect],
                        threshold: CGFloat = snapThreshold) -> CGRect {
        var xEdges: [CGFloat] = [], yEdges: [CGFloat] = []
        for s in screens {
            xEdges += [s.visibleFrame.minX, s.visibleFrame.maxX, s.frame.minX, s.frame.maxX]
            yEdges += [s.visibleFrame.minY, s.visibleFrame.maxY, s.frame.minY, s.frame.maxY]
        }
        for o in others {
            if o.minY - threshold <= frame.maxY && frame.minY <= o.maxY + threshold { xEdges += [o.minX, o.maxX] }
            if o.minX - threshold <= frame.maxX && frame.minX <= o.maxX + threshold { yEdges += [o.minY, o.maxY] }
        }
        var f = frame
        if let dx = bestShift(low: frame.minX, high: frame.maxX, edges: xEdges, threshold: threshold) {
            f.origin.x += dx
        }
        if let dy = bestShift(low: frame.minY, high: frame.maxY, edges: yEdges, threshold: threshold) {
            f.origin.y += dy
        }
        return f
    }

    /// Smallest shift (strictly under `threshold`) that puts either side of the span on an edge.
    private static func bestShift(low: CGFloat, high: CGFloat, edges: [CGFloat], threshold: CGFloat) -> CGFloat? {
        var best: CGFloat?
        for e in edges {
            for side in [low, high] {
                let d = e - side
                if abs(d) < threshold, best == nil || abs(d) < abs(best!) { best = d }
            }
        }
        return best
    }

    // MARK: Levels

    /// Window level for `AlwaysOnTop` (manual: -2 On Desktop … 2 Stay Topmost):
    /// - -2 On Desktop: just above the Finder's desktop icons, below every normal window. It still receives clicks
    ///   and drags (the Finder desktop window would swallow them if the skin were below the icon level).
    /// - -1 Bottom: below every normal application window, above On Desktop skins.
    /// - 0 Normal: the normal window level (comes to the front when clicked).
    /// - 1 Topmost: above normal application windows (floating level).
    /// - 2 Stay Topmost: above all other windows including Topmost skins and the Dock, below the menu bar.
    static func level(forAlwaysOnTop value: Int) -> NSWindow.Level {
        switch value {
        case ...(-2): return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case -1: return NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        case 0: return .normal
        case 1: return .floating
        default: return NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        }
    }

    /// Spaces / Mission Control behaviour. Every skin is on all Spaces and out of the window cycle. The manual says
    /// On Desktop, Normal, Topmost and Stay Topmost skins "stay visible when showing the desktop" — `stationary`
    /// keeps them in place during Show Desktop, Mission Control and Stage Manager — while Bottom skins do not
    /// (`transient`: hidden by Show Desktop / Mission Control). Topmost skins also show over full-screen apps.
    static func collectionBehavior(forAlwaysOnTop value: Int) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        behavior.insert(value == -1 ? .transient : .stationary)
        if value >= 1 { behavior.insert(.fullScreenAuxiliary) }
        return behavior
    }

    /// Stacking inside one level: "Load Order … controlling which overlapping skins appear in front when they share
    /// the same Position setting" — higher load order in front. Returns groups (one per level), back to front.
    static func stackingGroups<T>(_ items: [(item: T, alwaysOnTop: Int, loadOrder: Int, name: String)]) -> [[T]] {
        let byLevel = Dictionary(grouping: items) { min(max($0.alwaysOnTop, -2), 2) }
        return byLevel.keys.sorted().map { key in
            byLevel[key, default: []]
                .sorted { ($0.loadOrder, $0.name.lowercased()) < ($1.loadOrder, $1.name.lowercased()) }
                .map(\.item)
        }
    }
}

/// Skin window transparency (AlphaValue, OnHover, !Hide / !Show).
enum SkinVisibility {
    enum HoverMode: Int, CaseIterable {
        case none = 0, hide = 1, fadeIn = 2, fadeOut = 3

        var title: String {
            switch self {
            case .none: return "Do Nothing"
            case .hide: return "Hide"
            case .fadeIn: return "Fade In"
            case .fadeOut: return "Fade Out"
            }
        }
    }

    /// Window alpha for the current state. OnHover (manual): 1 Hide and 3 Fade out go "between the value in
    /// AlphaValue and hidden", 2 Fade in "between the value in AlphaValue and fully visible".
    static func targetAlpha(alphaValue: Int, onHover: Int, hovering: Bool, hidden: Bool) -> CGFloat {
        if hidden { return 0 }
        let base = CGFloat(min(max(alphaValue, 0), 255)) / 255
        guard hovering, let mode = HoverMode(rawValue: onHover) else { return base }
        switch mode {
        case .none: return base
        case .hide, .fadeOut: return 0
        case .fadeIn: return 1
        }
    }

    /// The manual gives Hide and Fade out the same description. Hide is treated as "get out of the way": while the
    /// skin is hidden under the mouse, clicks pass through to whatever is below; with Fade out the (invisible)
    /// skin keeps its mouse actions.
    static func passesClicksWhileHovering(onHover: Int) -> Bool { onHover == HoverMode.hide.rawValue }

    /// Fade duration in seconds from a millisecond setting (clamped; 0 = no animation).
    static func fadeSeconds(_ milliseconds: Int) -> TimeInterval {
        Double(min(max(milliseconds, 0), SkinState.maxFadeDuration)) / 1000
    }

    /// `!Draggable` / `!ClickThrough` / `!KeepOnScreen` / `!SnapEdges` setting: 1 on, 0 off, -1 toggle. Anything
    /// else (empty, text) counts as 1, the most common intent.
    static func flag(_ value: String, current: Bool) -> Bool {
        let t = value.trimmingCharacters(in: .whitespaces)
        let number = Int(t) ?? Double(t).flatMap { $0.isFinite ? Int(min(max($0, -2), 2)) : nil } ?? 1
        switch number {
        case -1: return !current
        case 0: return false
        default: return true
        }
    }
}
