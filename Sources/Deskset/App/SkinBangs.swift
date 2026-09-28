import AppKit
import DesksetCore

// Window, config and application bangs the engine hands to the host.
// Manual: https://docs.rainmeter.net/manual/bangs/ (skin, skin group and application bangs).
//
// The runtime answers the engine on the skin's executor (`HostBangs.kind`: supported or not, and which kind). Window
// bangs change the skin's window model there and go to other skins' runtimes (`SkinWindowModel`, `SkinDirectory`), as
// the group bangs do; what the config, menu and system bangs do happens on the main thread, where the runtime's
// request is applied (`SkinWindowController.applyHostBang`).

/// Which bangs the host handles, and of what kind: the request the runtime makes for them.
enum HostBangs {
    enum Kind: Equatable {
        case window, lifecycle, group, ui, system
    }

    /// The kind of a bang the engine left to the host (`Bang.name`); nil when it is not supported on macOS
    /// (!LoadLayout, !ResetStats, blur bangs, !SetAnchor…).
    static func kind(of name: String) -> Kind? {
        switch name {
        case "refresh", "refreshapp", "refreshgroup", "activateconfig", "deactivateconfig", "deactivateconfiggroup",
             "toggleconfig", "quit":
            return .lifecycle
        case "disablemouseactionskingroup", "clearmouseactionskingroup", "enablemouseactionskingroup",
             "togglemouseactionskingroup", "updategroup", "redrawgroup", "setvariablegroup":
            return .group
        case "move", "setwindowposition", "zpos", "zposgroup", "settransparency", "settransparencygroup", "draggable",
             "draggablegroup", "clickthrough", "clickthroughgroup", "keeponscreen", "keeponscreengroup", "snapedges",
             "snapedgesgroup", "autoselectscreen", "autoselectscreengroup", "show", "hide", "toggle", "showfade",
             "hidefade", "togglefade", "showgroup", "hidegroup", "togglegroup", "showfadegroup", "hidefadegroup",
             "togglefadegroup", "fadeduration", "fadedurationgroup":
            return .window
        case "skinmenu", "skincustommenu", "traymenu", "manage", "about", "editskin":
            return .ui
        case "setclip", "setwallpaper", "play", "playloop", "playstop":
            return .system
        default:
            return nil
        }
    }

    /// The bang as the main thread needs it: the file of !SetWallpaper, !Play and !PlayLoop as an absolute path (the
    /// skin resolves it, on its executor).
    static func preparedForMain(_ bang: Bang, of skin: Skin) -> Bang {
        switch bang.name {
        case "setwallpaper", "play", "playloop":
            var prepared = bang
            let file = bang.args.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if prepared.args.isEmpty { prepared.args = [""] }
            prepared.args[0] = skin.absolutePath(file)
            return prepared
        default:
            return bang
        }
    }
}

extension SkinWindowController {
    /// Does what a config, menu or system bang the runtime handed over does (`HostBangs`), on the main thread.
    func applyHostBang(_ host: HostBang) {
        // A stopped window still does what its skin asked for until the skin has closed: OnCloseAction's bangs
        // (`whileClosing`: the skin cannot reload or unload itself any more, `others`), and, for a skin on another
        // thread, what its work queued before the close asked. With the main executor both happen before `stop` returns.
        guard !isStopped || !hasClosed else { return }
        let bang = host.bang
        let a = bang.args
        // `[!ActivateConfig X][!Show X]`: X is loaded on the next run loop turn, so a bang for X that follows in the
        // same action runs after that load (it would find no such skin now). Loads keep their own order.
        if bang.name != "activateconfig" && bang.name != "toggleconfig",
           let target = BangCatalog.definition(for: bang.name)?.configArgument(in: a), target != "*",
           app.isLoadPending(target) {
            app.later { [weak self] _ in self?.applyHostBang(host) }
            return
        }
        func arg(_ i: Int) -> String { i < a.count ? a[i].trimmingCharacters(in: .whitespaces) : "" }
        /// Skins named by an optional trailing Config argument: empty → this skin, `*` → every active skin.
        func targets(_ index: Int) -> [SkinWindowController] {
            app.controllers(forConfigArgument: arg(index), current: self)
        }
        func group(_ index: Int) -> [SkinWindowController] { app.controllers(inGroup: arg(index)) }

        /// While OnCloseAction runs, the closing skin cannot reload or unload itself.
        func others(_ list: [SkinWindowController]) -> [SkinWindowController] {
            host.whileClosing ? list.filter { $0 !== self } : list
        }
        let isSelf = SkinLibrary.normalizedConfigName(arg(0)).caseInsensitiveCompare(config) == .orderedSame

        switch bang.name {
        // Config level. Loading, unloading and refreshing always happen on a later run loop turn, after the action
        // that asked for them has finished: a skin whose OnRefreshAction refreshes it (or another skin that
        // refreshes it back) must not recurse, and a skin must not be replaced while its own action runs.
        // Refreshes go in turn with the other loads asked for together (`AppController.inTurn`): every skin that follows
        // the appearance refreshes itself at once, and on another thread they would otherwise all be registered before
        // any of them loaded.
        case "refresh":
            if arg(0) == "*" {
                app.later { $0.refreshAll(rescan: false) }
            } else {
                for t in others(targets(0)) { app.later { $0.refreshInTurn(t) } }
            }
        case "refreshapp":
            app.later { $0.refreshAll(rescan: true) }
        case "refreshgroup":
            let list = others(group(0))
            app.later { app in list.forEach(app.refreshInTurn) }
        case "activateconfig":
            let config = arg(0)
            guard !config.isEmpty, !(host.whileClosing && isSelf) else { return }
            let file = arg(1).isEmpty ? nil : arg(1)
            let sender = self.config
            app.later(loading: config) { app in app.activateFromBang(config: config, file: file, sender: sender) }
        case "deactivateconfig":
            let list = others(arg(0).isEmpty ? [self] : targets(0))
            for t in list { app.later { $0.deactivate(t, fade: true) } }
        case "deactivateconfiggroup":
            let list = others(group(0))
            app.later { app in list.forEach { app.deactivate($0, fade: true) } }
        case "toggleconfig":
            let config = arg(0)
            guard !config.isEmpty, !(host.whileClosing && isSelf) else { return }
            let file = arg(1).isEmpty ? nil : arg(1)
            // Decided when it runs: an earlier bang of the same action may have loaded or unloaded the config.
            app.later(loading: config) { app in
                if let running = app.controller(for: config) {
                    app.deactivate(running, fade: true)
                } else {
                    app.activate(config: config, file: file, fade: true)
                }
            }

        // Menus and windows
        case "skinmenu":
            if let t = targets(0).first { app.popUpMenu(app.skinMenu(for: t, includeCustomItems: true)) }
        case "skincustommenu":
            if let t = targets(0).first, let menu = app.customSkinMenu(for: t) { app.popUpMenu(menu) }
        case "traymenu":
            app.showMainMenu()
        case "manage":
            // !Manage [TabName] [Config] [File]
            let config = arg(1).isEmpty ? nil : SkinLibrary.normalizedConfigName(arg(1))
            app.showManageWindow(selecting: config, file: arg(2).isEmpty ? nil : arg(2))
        case "about":
            if arg(0).lowercased() == "log" { Workspace.edit(Paths.logFile) } else { app.showAbout() }
        case "editskin":
            // !EditSkin [Config] [File]
            if let t = targets(0).first {
                let file = arg(1).isEmpty ? t.file : arg(1)
                CodeEditorRouter.open(file: t.fileURL.deletingLastPathComponent().appendingPathComponent(file), app: app)
            } else if !arg(0).isEmpty {
                let dir = SkinLibrary.directory(for: SkinLibrary.normalizedConfigName(arg(0)), root: app.skinsDirectory)
                if !arg(1).isEmpty { CodeEditorRouter.open(file: dir.appendingPathComponent(arg(1)), app: app) }
            }

        // Operating system
        case "setclip":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.first ?? "", forType: .string)
        case "setwallpaper":
            // The path is absolute already (`HostBangs.preparedForMain`).
            setWallpaper(path: arg(0), position: arg(1))
        case "play", "playloop":
            SoundPlayer.play(path: arg(0), loop: bang.name == "playloop")
        case "playstop":
            SoundPlayer.stop()
        case "quit":
            app.later { _ in NSApp.terminate(nil) }

        default:
            // Window and group bangs never come here (the runtime carries them out), nor unsupported ones.
            break
        }
    }

    /// !SetWallpaper File [Position] on every screen. Position: Center, Tile, Stretch, Fit, Fill (default), Span.
    /// macOS cannot tile a picture; Tile shows it unscaled like Center.
    private func setWallpaper(path: String, position: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            Log.write("!SetWallpaper: file not found: \(path)", level: .warning, source: config)
            return
        }
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        switch position.lowercased() {
        case "center", "tile":
            options[.imageScaling] = NSImageScaling.scaleNone.rawValue
            options[.allowClipping] = false
        case "stretch":
            options[.imageScaling] = NSImageScaling.scaleAxesIndependently.rawValue
        case "fit":
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = false
        default:
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = true
        }
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: options)
            } catch {
                Log.write("!SetWallpaper failed: \(error.localizedDescription)", level: .error, source: config)
            }
        }
        // Skins on other threads read the desktop pictures as published (Chameleon): the new one at once.
        DesktopInputs.mainScreenDesktop.refresh()
        DesktopInputs.displayDesktops.refresh()
        DesktopInputs.desktopFillColor.refresh()
    }
}

/// `Play` / `PlayLoop` / `PlayStop`: one sound at a time, like the manual describes.
enum SoundPlayer {
    private static var current: NSSound?

    static func play(path: String, loop: Bool) {
        stop()
        guard let sound = NSSound(contentsOfFile: path, byReference: true) else {
            Log.write("Cannot play \(path)", level: .warning)
            return
        }
        sound.loops = loop
        sound.play()
        current = sound
    }

    static func stop() {
        current?.stop()
        current = nil
    }
}

/// `WindowX` / `WindowY` / `AnchorX` / `AnchorY` values as used by !SetWindowPosition
/// (https://docs.rainmeter.net/manual/settings/skin-sections/#WindowX): pixels, or a formula in parentheses, with
/// optional trailing `%` (percent of the screen — or, for anchors, of the skin), `R` / `B` (from the right / bottom
/// edge) and `@N` (screen N, 1-based; `@0` is the whole desktop; default: the primary screen).
enum WindowPosition {
    struct Coordinate: Equatable {
        var value: Double
        var percent = false
        var fromEnd = false
        var screen: Int?
    }

    static func parse(_ raw: String, endLetter: Character) -> Coordinate? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var screen: Int?
        if let at = text.lastIndex(of: "@") {
            let number = text[text.index(after: at)...].trimmingCharacters(in: .whitespaces)
            guard let n = Int(number), (0...32).contains(n) else { return nil }
            screen = n
            text = String(text[..<at]).trimmingCharacters(in: .whitespaces)
        }
        var percent = false, fromEnd = false
        for _ in 0..<2 {
            if let last = text.last, last == "%" {
                percent = true
                text.removeLast()
            } else if let last = text.last, last.uppercased() == String(endLetter) {
                fromEnd = true
                text.removeLast()
            }
            text = text.trimmingCharacters(in: .whitespaces)
        }
        guard let value = OptionValue.number(text), value.isFinite else { return nil }
        return Coordinate(value: min(max(value, -1e6), 1e6), percent: percent, fromEnd: fromEnd, screen: screen)
    }

    /// Top-left position (skin coordinates) for the given values, or nil when a value cannot be read.
    static func resolve(x: String, y: String, anchorX: String, anchorY: String, skinSize: CGSize,
                        screens: [WindowGeometry.Screen]) -> (x: Double, y: Double)? {
        guard let cx = parse(x, endLetter: "R"), let cy = parse(y, endLetter: "B"),
              let ax = parse(anchorX, endLetter: "R"), let ay = parse(anchorY, endLetter: "B") else { return nil }
        let ph = WindowGeometry.primaryHeight(screens)
        func area(_ n: Int?) -> CGRect {
            let rects = screens.map { r -> CGRect in
                CGRect(x: r.frame.minX, y: ph - r.frame.maxY, width: r.frame.width, height: r.frame.height)
            }
            guard let first = rects.first else { return CGRect(x: 0, y: 0, width: 1920, height: 1080) }
            guard let n else { return first }
            if n == 0 { return rects.dropFirst().reduce(first) { $0.union($1) } }
            return n <= rects.count ? rects[n - 1] : first
        }
        func place(_ c: Coordinate, start: CGFloat, length: CGFloat) -> Double {
            let offset = c.percent ? c.value / 100 * Double(length) : c.value
            return c.fromEnd ? Double(start + length) - offset : Double(start) + offset
        }
        func anchor(_ c: Coordinate, length: CGFloat) -> Double {
            let offset = c.percent ? c.value / 100 * Double(length) : c.value
            return c.fromEnd ? Double(length) - offset : offset
        }
        let xArea = area(cx.screen), yArea = area(cy.screen ?? cx.screen)
        let px = place(cx, start: xArea.minX, length: xArea.width) - anchor(ax, length: skinSize.width)
        let py = place(cy, start: yArea.minY, length: yArea.height) - anchor(ay, length: skinSize.height)
        return (px, py)
    }
}
