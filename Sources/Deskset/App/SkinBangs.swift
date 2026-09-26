import AppKit
import DesksetCore

// Window, config and application bangs the engine hands to the host.
// Manual: https://docs.rainmeter.net/manual/bangs/ (skin, skin group and application bangs).

extension SkinController {
    /// Handles a bang the engine does not handle itself. Returns false when it is not supported on macOS (the
    /// engine then records a compatibility note).
    func handleHostBang(_ bang: Bang) -> Bool {
        guard !isStopped else { return true }
        let a = bang.args
        // `[!ActivateConfig X][!Show X]`: X is loaded on the next run loop turn, so a bang for X that follows in the
        // same action runs after that load (it would find no such skin now). Loads keep their own order.
        if bang.name != "activateconfig" && bang.name != "toggleconfig",
           let target = BangCatalog.definition(for: bang.name)?.configArgument(in: a), target != "*",
           app.isLoadPending(target) {
            app.later { [weak self] _ in _ = self?.handleHostBang(bang) }
            return true
        }
        func arg(_ i: Int) -> String { i < a.count ? a[i].trimmingCharacters(in: .whitespaces) : "" }
        /// Skins named by an optional trailing Config argument: empty → this skin, `*` → every active skin.
        func targets(_ index: Int) -> [SkinController] { app.controllers(forConfigArgument: arg(index), current: self) }
        func group(_ index: Int) -> [SkinController] { app.controllers(inGroup: arg(index)) }
        func update(_ list: [SkinController], _ change: (inout SkinState) -> Void) {
            for t in list {
                app.state.update(t.config, change)
                t.applyWindowSettings()
            }
            app.skinSettingsChanged()
        }
        func setFlag(_ list: [SkinController], _ key: WritableKeyPath<SkinState, Bool>) {
            for t in list {
                app.state.update(t.config) { $0[keyPath: key] = SkinVisibility.flag(arg(0), current: $0[keyPath: key]) }
                t.applyWindowSettings()
            }
            app.skinSettingsChanged()
        }
        func zPosition() -> Int { min(max(OptionValue.int(arg(0)) ?? 0, -2), 2) }
        func alpha() -> Int { min(max(OptionValue.int(arg(0)) ?? 255, 0), 255) }
        func milliseconds() -> Int {
            let v = OptionValue.number(arg(0)) ?? 250
            return v.isFinite ? Int(min(max(v, 0), Double(SkinState.maxFadeDuration))) : 250
        }
        func setZPos(_ list: [SkinController], _ value: Int) {
            update(list) { $0.alwaysOnTop = value }
            list.forEach { if $0.isShown && app.presentsWindows { $0.window.orderFrontRegardless() } }
            // Skins sharing the new Position are stacked by load order again (like the menu / Manage window do).
            app.restack()
        }

        /// While OnCloseAction runs, the closing skin cannot reload or unload itself.
        func others(_ list: [SkinController]) -> [SkinController] { isClosing ? list.filter { $0 !== self } : list }
        let isSelf = SkinLibrary.normalizedConfigName(arg(0)).caseInsensitiveCompare(config) == .orderedSame

        switch bang.name {
        // Config level. Loading, unloading and refreshing always happen on a later run loop turn, after the action
        // that asked for them has finished: a skin whose OnRefreshAction refreshes it (or another skin that
        // refreshes it back) must not recurse, and a skin must not be replaced while its own action runs.
        case "refresh":
            if arg(0) == "*" {
                app.later { $0.refreshAll(rescan: false) }
            } else {
                for t in others(targets(0)) { app.later { $0.refresh(t) } }
            }
        case "refreshapp":
            app.later { $0.refreshAll(rescan: true) }
        case "refreshgroup":
            let list = others(group(0))
            app.later { app in list.forEach(app.refresh) }
        case "activateconfig":
            let config = arg(0)
            guard !config.isEmpty, !(isClosing && isSelf) else { return true }
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
            guard !config.isEmpty, !(isClosing && isSelf) else { return true }
            let file = arg(1).isEmpty ? nil : arg(1)
            // Decided when it runs: an earlier bang of the same action may have loaded or unloaded the config.
            app.later(loading: config) { app in
                if let running = app.controller(for: config) {
                    app.deactivate(running, fade: true)
                } else {
                    app.activate(config: config, file: file, fade: true)
                }
            }
        case "disablemouseactionskingroup", "clearmouseactionskingroup", "enablemouseactionskingroup",
             "togglemouseactionskingroup":
            // "operate on the [Rainmeter] section of a named Group of skins": !XMouseAction Rainmeter MouseActions
            // in each skin of the group.
            let verb = String(bang.name.dropLast("skingroup".count))
            for t in group(1) where !t.isStopped {
                t.skin.perform(Bang(name: verb, args: ["Rainmeter", a.first ?? ""]))
            }
        case "updategroup":
            group(0).forEach { $0.skin.update() }
        case "redrawgroup":
            group(0).forEach { $0.skin.redraw() }
        case "setvariablegroup":
            // !SetVariableGroup Variable Value Group
            for t in group(2) where !t.isStopped {
                t.skin.perform(Bang(name: "setvariable", args: [arg(0), a.count > 1 ? a[1] : ""]))
            }

        // Window position and behaviour
        case "move":
            guard let x = OptionValue.number(arg(0)), let y = OptionValue.number(arg(1)) else { return true }
            targets(2).forEach { $0.moveTo(x: x, y: y) }
        case "setwindowposition":
            // !SetWindowPosition WindowX WindowY [AnchorX AnchorY] [Config]
            let configIndex = a.count >= 5 ? 4 : (a.count == 3 ? 2 : -1)
            let list = configIndex >= 0 ? targets(configIndex) : [self]
            for t in list {
                let size = t.window.frame.size
                let anchor = a.count >= 4 ? (arg(2), arg(3)) : ("0", "0")
                if let p = WindowPosition.resolve(x: arg(0), y: arg(1), anchorX: anchor.0, anchorY: anchor.1,
                                                  skinSize: size, screens: WindowGeometry.currentScreens()) {
                    t.moveTo(x: p.x, y: p.y)
                }
            }
        case "zpos":
            setZPos(targets(1), zPosition())
        case "zposgroup":
            setZPos(group(1), zPosition())
        case "settransparency":
            let list = targets(1)
            list.forEach { $0.clearFadedAlpha() }
            update(list) { $0.alphaValue = alpha() }
        case "settransparencygroup":
            let list = group(1)
            list.forEach { $0.clearFadedAlpha() }
            update(list) { $0.alphaValue = alpha() }
        case "draggable": setFlag(targets(1), \.draggable)
        case "draggablegroup": setFlag(group(1), \.draggable)
        case "clickthrough": setFlag(targets(1), \.clickThrough)
        case "clickthroughgroup": setFlag(group(1), \.clickThrough)
        case "keeponscreen":
            setFlag(targets(1), \.keepOnScreen)
            targets(1).forEach { $0.windowMoved() }
        case "keeponscreengroup":
            setFlag(group(1), \.keepOnScreen)
            group(1).forEach { $0.windowMoved() }
        case "snapedges": setFlag(targets(1), \.snapEdges)
        case "snapedgesgroup": setFlag(group(1), \.snapEdges)
        case "autoselectscreen":
            // Positions are kept in desktop coordinates whatever the setting; it decides which monitor the
            // monitor variables without @N refer to (see `SkinController.environment(for:)`).
            setFlag(targets(1), \.autoSelectScreen)
        case "autoselectscreengroup":
            setFlag(group(1), \.autoSelectScreen)

        // Visibility
        case "show": targets(0).forEach { $0.setHidden(false, fade: false) }
        case "hide": targets(0).forEach { $0.setHidden(true, fade: false) }
        case "toggle": targets(0).forEach { $0.setHidden(!$0.isHiddenByBang, fade: false) }
        case "showfade": targets(0).forEach { $0.setHidden(false, fade: true) }
        case "hidefade": targets(0).forEach { $0.setHidden(true, fade: true) }
        case "togglefade": targets(0).forEach { $0.setHidden(!$0.isHiddenByBang, fade: true) }
        case "showgroup": group(0).forEach { $0.setHidden(false, fade: false) }
        case "hidegroup": group(0).forEach { $0.setHidden(true, fade: false) }
        case "togglegroup": group(0).forEach { $0.setHidden(!$0.isHiddenByBang, fade: false) }
        case "showfadegroup": group(0).forEach { $0.setHidden(false, fade: true) }
        case "hidefadegroup": group(0).forEach { $0.setHidden(true, fade: true) }
        case "togglefadegroup": group(0).forEach { $0.setHidden(!$0.isHiddenByBang, fade: true) }
        case "fadeduration":
            let ms = milliseconds()
            update(targets(1)) { $0.fadeDuration = ms }
        case "fadedurationgroup":
            let ms = milliseconds()
            update(group(1)) { $0.fadeDuration = ms }

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
                CodeEditorRouter.open(file: t.skin.directory.appendingPathComponent(file), app: app)
            } else if !arg(0).isEmpty {
                let dir = SkinLibrary.directory(for: SkinLibrary.normalizedConfigName(arg(0)), root: app.skinsDirectory)
                if !arg(1).isEmpty { CodeEditorRouter.open(file: dir.appendingPathComponent(arg(1)), app: app) }
            }

        // Operating system
        case "setclip":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.first ?? "", forType: .string)
        case "setwallpaper":
            setWallpaper(path: skin.absolutePath(arg(0)), position: arg(1))
        case "play", "playloop":
            SoundPlayer.play(path: skin.absolutePath(arg(0)), loop: bang.name == "playloop")
        case "playstop":
            SoundPlayer.stop()
        case "quit":
            app.later { _ in NSApp.terminate(nil) }

        default:
            // !LoadLayout, !ResetStats, blur bangs, !SetAnchor…: not supported.
            return false
        }
        return true
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
