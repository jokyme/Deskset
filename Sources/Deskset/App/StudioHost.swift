import AppKit
import DesksetCore

/// A host whose skins run in the app on live data: the widgets on the desktop (`SkinRuntime`) and the Studio's own
/// instance of the widget it edits (`StudioHost`). Their plugins read the shared services — sound, the player that is
/// playing, the weather — and may ask macOS for what those need; a skin read for a thumbnail, a dry run or `--render`
/// does not.
protocol LiveSkinHost: SkinHost {
    /// Whether the skin's updates are paused (sleep, a locked screen): what reads its values then must not keep the
    /// shared services busy (NowPlaying's polling of the players).
    var areUpdatesPaused: Bool { get }
    /// The display the widget's window is on (nil: not known), from what the host knows of the window: a skin's
    /// runtime has it from the window's facts, so any thread the host's skin runs on may ask.
    var windowDisplay: CGDirectDisplayID? { get }
}

/// The host of the Studio's own instance of the widget it edits. The widget on the desktop keeps running as it is; this
/// instance loads the editing session's text from memory and is what the canvas draws. It has no window of its own:
/// text and images are measured as the desktop measures them, its screens and window place are the desktop copy's, and
/// of its actions it runs only what stays inside the widget (`StudioActionPolicy`) — the rest is recorded, since the
/// desktop copy does it. What it would log is kept here, not written to the app's log a second time.
///
/// It runs on the main thread, where the desktop copy's window controller is, and reads that controller, never the
/// desktop copy's skin (which may run on another thread): the window as the controller last told its runtime
/// (`SkinWindowController.publishedFacts`), with the environment store's screens and paths.
final class StudioHost: LiveSkinHost {
    /// The widget on the desktop (its window's place and screens).
    weak var desktop: SkinWindowController?
    let policy = StudioActionPolicy()
    /// The editing session pauses its instance with the widgets on the desktop (`EditingSession.setUpdatesPaused`).
    var updatesPaused = false
    /// The window of the last desktop copy that had started (placed): a reload's new copy, linked before it started,
    /// has not placed its window yet, and the old one's stays where the widget is until then.
    private var knownWindow: SkinWindowFacts?

    var areUpdatesPaused: Bool { updatesPaused }

    /// The desktop copy's window, as its controller last told its runtime (main thread).
    var desktopWindow: SkinWindowFacts? {
        if let c = desktop, c.isStarted, let facts = c.publishedFacts { knownWindow = facts }
        return knownWindow
    }

    /// The desktop copy's display: a Chameleon widget on a second display takes its colors from that wallpaper.
    var windowDisplay: CGDirectDisplayID? { desktopWindow?.display }
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
    /// Debug builds compare it with the live window while the desktop copy runs on the main executor.
    func environment(for skin: Skin) -> SkinEnvironment {
        var env: SkinEnvironment
        if let window = desktopWindow {
            env = EnvironmentStore.shared.environment(windowFrame: window.frame, zPosition: window.settings.zPosition,
                                                      autoSelectScreen: window.settings.autoSelectScreen)
            #if DEBUG
            if let c = desktop, c.isStarted, !c.isStopped, c.heldMove == nil, SnapshotAudit.isActive(c.runtime) {
                SnapshotAudit.compare("the Studio's environment", c.runtime, snapshot: env, live: c.environment,
                                      sides: ("the window facts", "the window"))
            }
            #endif
        } else {
            env = EnvironmentStore.shared.environment(windowFrame: nil)
        }
        env.windowFrame.width = skin.width
        env.windowFrame.height = skin.height
        return env
    }

    /// The canvas takes no pointer input while the Studio designs.
    func skinWindowTakesPointer(_ skin: Skin) -> Bool { false }
}
