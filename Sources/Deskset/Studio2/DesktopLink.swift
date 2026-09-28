import AppKit
import DesksetCore

/// The new Studio window's one way to the widget on the desktop. Everything the window knows or asks of the desktop
/// copy goes through here — which copy is current (`EditingSession.currentDesktop` / `runningDesktop`), its reloads,
/// what it wrote itself, where its file is — so a change in how the desktop copy runs (its own thread, a runtime that
/// takes messages) changes this file only. The window never reads the desktop copy's `Skin` itself.
final class DesktopLink {
    /// What happened to the widget on the desktop.
    enum Change {
        /// It was loaded again. `own`: the reload the session asked for (a step, an undo) — the Studio's instance
        /// already shows it; else the Studio's instance was loaded again too.
        case reloaded(own: Bool)
        /// It is no longer on the desktop (unloaded).
        case unloaded
    }

    unowned let app: AppController
    let session: EditingSession
    /// Told when the widget on the desktop changes (main thread).
    var onChange: ((Change) -> Void)?
    /// The desktop copy last linked (`link`).
    private weak var linked: SkinController?
    /// `!WriteKeyValue` bangs the desktop copy had run when the files were last looked at (`takeOwnWrites`).
    private var keyValueWrites = 0
    private var observer: NSObjectProtocol?
    private(set) var isUnloaded = false

    init(app: AppController, session: EditingSession) {
        self.app = app
        self.session = session
        observer = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged, object: app, queue: nil) {
            [weak self] _ in
            self?.desktopChanged()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Links the widget `c` on the desktop to the session (`EditingSession.bind`) and loads the Studio's instance
    /// when the session has none or the desktop runs another file. Returns true when it runs another file.
    @discardableResult
    func link(_ c: SkinController) -> Bool {
        linked = c
        isUnloaded = false
        keyValueWrites = c.skin.keyValueWrites
        let otherFile = session.bind(desktop: c)
        if session.studioSkin == nil || otherFile { session.reloadStudioSkin(notify: false) }
        return otherFile
    }

    /// The widgets on the desktop changed (one loaded, reloaded or unloaded): when it is this widget, the session
    /// follows the new copy. After a reload the session asked for only the link changes, and what the widget wrote as
    /// it loaded is its own; after any other (its menu's Refresh, `!Refresh`, another variant) the Studio's instance
    /// loads again too.
    func desktopChanged() {
        guard let now = session.currentDesktop, !now.isStopped else {
            guard !isUnloaded, linked != nil else { return }
            isUnloaded = true
            onChange?(.unloaded)
            return
        }
        guard now !== linked else { return }
        isUnloaded = false
        let own = session.takeOwnReload(now)
        linked = now
        keyValueWrites = now.skin.keyValueWrites
        let otherFile = session.bind(desktop: now)
        if own && !otherFile {
            session.absorbDesktopWrites()
            onChange?(.reloaded(own: true))
            return
        }
        session.absorbDesktopWrites(notify: false)
        session.reloadStudioSkin()
        onChange?(.reloaded(own: false))
    }

    /// Whether the widget runs on the desktop now.
    var isOnDesktop: Bool { session.runningDesktop != nil }

    /// The config of the widget ("Stationery\System").
    var config: String { session.config }

    /// The file the desktop runs (the widget's main .ini).
    var fileURL: URL? { session.runningDesktop.map { $0.skin.fileURL } ?? session.studioSkin?.fileURL }

    /// Whether the desktop copy wrote its files itself (`!WriteKeyValue`) since the files were last looked at: such a
    /// change does not reload the widget (Rainmeter does not refresh for it either).
    func takeOwnWrites() -> Bool {
        guard let c = session.runningDesktop else { return false }
        let writes = c.skin.keyValueWrites
        defer { keyValueWrites = writes }
        return writes != keyValueWrites
    }

    /// Shows the widget's main file in Finder.
    func showInFinder() {
        guard let url = fileURL else { return }
        guard app.presentsWindows else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The widget's file as it is shown in the name's popover: its path under the Skins folder ("Skins/Nocturne/
    /// Nocturne.ini"), else the whole path.
    var displayPath: String? {
        guard let url = fileURL?.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        let skins = app.skinsDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.path
        guard path.hasPrefix(skins + "/") else { return path }
        return "Skins/" + path.dropFirst(skins.count + 1)
    }

    // MARK: The desktop around the widget (the canvas's backdrop, Show on Desktop)

    /// The widget's window on the desktop (nil: not on the desktop). Its level and order are the window's; its skin is
    /// never read through it.
    var desktopWindow: NSWindow? { session.runningDesktop?.window }

    /// Where the widget is on the desktop (its window's frame, global coordinates).
    var desktopFrame: CGRect? { desktopWindow?.frame }

    /// The screen the widget is on: its window's, else the one its frame overlaps most, else the main one.
    var desktopScreen: NSScreen? {
        if let screen = desktopWindow?.screen { return screen }
        guard let frame = desktopFrame else { return NSScreen.main }
        return NSScreen.screens.max { a, b in
            a.frame.intersection(frame).width * a.frame.intersection(frame).height
                < b.frame.intersection(frame).width * b.frame.intersection(frame).height
        } ?? NSScreen.main
    }

    /// The windows of the other widgets that show on the desktop now (for the neighbours around this one: their
    /// pictures are taken from the windows, never from their skins).
    func otherWidgetWindows() -> [NSWindow] {
        let mine = session.runningDesktop
        return app.controllers.values.filter { $0 !== mine && !$0.isStopped }.map(\.window)
            .filter { $0.isVisible && $0.alphaValue > 0.01 }
    }

    /// Does for real what the Studio's instance held back (Interact's "Open"): the widget on the desktop runs it, in
    /// its own place (its thread, its policy: none).
    func perform(_ recorded: StudioActionPolicy.Recorded) {
        guard recorded.kind != .file, let skin = session.runningDesktop?.skin else { return }
        let action = recorded.kind == .execute ? "[\"\(recorded.name)\"]" : "[\(recorded.text)]"
        let run = { skin.execute(action, from: nil) }
        if skin.executor.isCurrent { run() } else { skin.async(run) }
    }

    /// Where the widget comes from, for the copy sentence under its name.
    var provenance: StudioProvenance {
        let root = SkinLibrary.normalizedConfigName(config).split(separator: "\\").first.map(String.init) ?? config
        let builtIn = app.defaultSkinsSource.flatMap { DefaultSkins.rootConfigs(in: $0) }?
            .contains { $0.lastPathComponent.caseInsensitiveCompare(root) == .orderedSame } ?? false
        if builtIn { return .builtIn }
        let author = session.studioSkin.flatMap { ManageModel.metadataValue($0.metadata, "Author") }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return author.isEmpty ? .madeByYou : .rainmeter(author: author)
    }
}

/// Where a widget comes from. knows INI widgets only: the ones that
/// come with Deskset, skins with an author (Rainmeter skins, edited as they are: compatibility mode), and skins without
/// one (made here).
enum StudioProvenance: Equatable {
    case builtIn
    case madeByYou
    case rainmeter(author: String)
}
