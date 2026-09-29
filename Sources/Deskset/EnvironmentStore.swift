import AppKit
import DesksetCore

/// What skins read of the world outside their windows (docs/skin-threading.md §4.2): the screens and their work areas,
/// `#SETTINGSPATH#`, `#PROGRAMPATH#`, `#CONFIGEDITOR#` and the Mac's appearance. The main thread works these out from
/// AppKit and publishes them; a skin on a thread of its own reads what was published, without waiting.
///
/// - A read on the main thread works the screens, the config editor and the appearance out again and publishes them,
///   as every read did while all skins ran there (`MainPublished`), so a skin of the main executor sees exactly what it
///   always saw.
/// - The app publishes all of it at launch, the screens again when displays change and the config editor when Settings ▸
///   Editor changes (`publish()`, `publishScreens()`, `publishConfigEditor()`); the appearance is `MacAppearance.current`,
///   which the app publishes when it changes. A value older than its age limit (a minute: they are published on
///   change) is asked for again once, in the background.
/// - `#SETTINGSPATH#` is set, not worked out: the command-line modes and the self-tests point it at a folder of their own.
///
/// A skin's own window place, Z position and screen come from its window model (`SkinWindowModel`); `environment` puts
/// the two together.
final class EnvironmentStore {
    static let shared = EnvironmentStore()

    /// The screens (AppKit's frames and visible frames; the primary one first). Published again whenever displays or
    /// their work areas change (`publishScreens`, from `didChangeScreenParametersNotification`); the age limit is only a
    /// safety net, long enough that skins redrawing on other threads do not wake the main thread for it.
    let screens = MainPublished<[WindowGeometry.Screen]>(maxAge: 60, initial: []) { WindowGeometry.currentScreens() }
    /// `#CONFIGEDITOR#` (`Workspace.configEditorPath`, which looks the app up at most once a minute).
    let configEditor = MainPublished<String>(maxAge: 60, initial: SkinEnvironment().configEditor) {
        Workspace.configEditorPath
    }
    private let settings = Guarded(Paths.appSupport.path + "/")
    /// `#PROGRAMPATH#`, with a trailing slash.
    let programPath = Bundle.main.bundleURL.path + "/"

    /// `#SETTINGSPATH#` of every skin, with a trailing slash: the app's settings folder. The command-line modes and the
    /// self-tests point it at a folder of their own, so that skins keeping what people type there (the Stationery
    /// widgets' `Stationery.inc`) never read or write the user's. Any thread.
    var settingsPath: String {
        get { settings.current }
        set { settings.access { $0 = newValue } }
    }

    /// Main thread: works everything out and publishes it (at launch).
    func publish() {
        publishScreens()
        publishConfigEditor()
        MacAppearance.current.refresh()
    }

    /// Main thread: the displays were added, removed or rearranged, or their work areas changed.
    func publishScreens() {
        screens.refresh()
    }

    /// Main thread: Settings ▸ Editor changed.
    func publishConfigEditor() {
        configEditor.refresh()
    }

    /// The screens as the skin reads them now: worked out on the main thread, the published ones elsewhere.
    var currentScreens: [WindowGeometry.Screen] { screens.value() }

    /// The environment of a skin whose window has `windowFrame` (AppKit coordinates; nil: no window) at Z position
    /// `zPosition`; with `autoSelectScreen` the monitor variables without `@N` refer to the window's screen instead of
    /// the primary one ("the WindowX/WindowY @N settings are dynamically set based on the position of the window").
    /// Any thread.
    func environment(windowFrame: CGRect?, zPosition: Int = 0, autoSelectScreen: Bool = false) -> SkinEnvironment {
        let screens = currentScreens
        var env = EnvironmentStore.environment(windowFrame: windowFrame, screens: screens, settingsPath: settingsPath,
                                               programPath: programPath, configEditor: configEditor.value(),
                                               appearance: MacAppearance.current.value())
        env.zPosition = zPosition
        if autoSelectScreen, let frame = windowFrame, frame.width > 1 || frame.height > 1,
           let index = WindowGeometry.screenIndex(for: frame, screens: screens), index < env.screens.count {
            env.currentScreen = index
        }
        return env
    }

    /// Screens and window frame in skin coordinates (top-left origin at the primary screen's top-left corner).
    static func environment(windowFrame: CGRect?, screens: [WindowGeometry.Screen], settingsPath: String,
                            programPath: String, configEditor: String, appearance: SkinAppearance) -> SkinEnvironment {
        let ph = Double(WindowGeometry.primaryHeight(screens))
        func topLeft(_ r: CGRect) -> SkinRect {
            SkinRect(x: Double(r.minX), y: ph - Double(r.maxY), width: Double(r.width), height: Double(r.height))
        }
        let list = screens.map { SkinScreen(area: topLeft($0.frame), workArea: topLeft($0.visibleFrame)) }
        return SkinEnvironment(windowFrame: windowFrame.map(topLeft) ?? SkinRect(),
                               screens: list.isEmpty ? SkinEnvironment().screens : list,
                               settingsPath: settingsPath, programPath: programPath, configEditor: configEditor,
                               appearance: appearance)
    }
}
