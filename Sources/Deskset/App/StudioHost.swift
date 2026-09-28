import AppKit
import DesksetCore

/// A host whose skins run in the app on live data: the widgets on the desktop (`SkinController`) and the Studio's own
/// instance of the widget it edits (`StudioHost`). Their plugins read the shared services — sound, the player that is
/// playing, the weather — and may ask macOS for what those need; a skin read for a thumbnail, a dry run or `--render`
/// does not.
protocol LiveSkinHost: SkinHost {
    /// Whether the skin's updates are paused (sleep, a locked screen): what reads its values then must not keep the
    /// shared services busy (NowPlaying's polling of the players).
    var areUpdatesPaused: Bool { get }
    /// The screen the widget's window is on (nil: not known; main thread).
    var windowScreen: NSScreen? { get }
}

extension SkinController: LiveSkinHost {
    var windowScreen: NSScreen? { window.screen }
}

/// The host of the Studio's own instance of the widget it edits. The widget on the desktop keeps running as it is; this
/// instance loads the editing session's text from memory and is what the canvas draws. It has no window of its own:
/// text and images are measured as the desktop measures them, its screens and window place are the desktop copy's, and
/// of its actions it runs only what stays inside the widget (`StudioActionPolicy`) — the rest is recorded, since the
/// desktop copy does it. What it would log is kept here, not written to the app's log a second time.
final class StudioHost: LiveSkinHost {
    /// The widget on the desktop (its window's place and screens).
    weak var desktop: SkinController?
    let policy = StudioActionPolicy()
    /// The editing session pauses its instance with the widgets on the desktop (`EditingSession.setUpdatesPaused`).
    var updatesPaused = false
    /// The canvas passes the pointer to the instance (the Studio's Interact).
    var takesPointer = false
    /// The Mac's look the instance sees (the Studio's preview; nil: the desktop copy's).
    var appearance: SkinAppearance?

    var areUpdatesPaused: Bool { updatesPaused }

    /// The desktop copy's screen: a Chameleon widget on a second display takes its colors from that wallpaper.
    var windowScreen: NSScreen? { desktop?.window.screen }
    /// The instance's log lines, the last `logLimit`.
    private(set) var logs: [(level: SkinLogLevel, message: String)] = []
    var logLimit = 200

    /// The canvas draws the instance at the widget's own update rate (its timer), as it drew the desktop copy.
    func skinNeedsDisplay(_ skin: Skin) {}

    /// Window, config and app bangs never get here (the policy records them first); anything else that does is
    /// recorded too.
    func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        _ = policy.skin(skin, allows: bang)
        return true
    }

    /// Bangs for other widgets (a Config argument, or `*`) are the desktop copy's to send.
    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {}

    func skin(_ skin: Skin, execute target: String, arguments: [String]) {}

    func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {
        logs.append((level, message))
        if logs.count > logLimit { logs.removeFirst(logs.count - logLimit) }
    }

    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
        SkinRenderer.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
    }

    func imageSize(atPath path: String) -> (width: Double, height: Double)? { Images.size(atPath: path) }

    /// The desktop copy's screens and window place (`#CURRENTCONFIGX#`, `#WORKAREAWIDTH#`…), with this instance's size.
    func environment(for skin: Skin) -> SkinEnvironment {
        var env: SkinEnvironment
        if let c = desktop, !c.isStopped {
            env = c.environment(for: skin)
        } else {
            env = SkinController.environment(windowFrame: nil)
        }
        env.windowFrame.width = skin.width
        if let appearance { env.appearance = appearance }
        env.windowFrame.height = skin.height
        return env
    }

    /// The canvas takes no pointer input while the Studio designs; it does while it interacts.
    func skinWindowTakesPointer(_ skin: Skin) -> Bool { takesPointer }
}
