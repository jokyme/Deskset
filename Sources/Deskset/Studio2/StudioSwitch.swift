import AppKit

/// Which Studio opens: the new window (`StudioWindowController`) while the defaults key `StudioV2` is on, else the old
/// one (the default until the new one has been tried by people). A hidden item of the menu bar menu turns it on and
/// off: hold Option on "About Deskset" and it reads "Use New Studio".
///
/// Headless (self-tests, snapshots) the user's defaults are never read: `headlessValue` says, off unless a check turns
/// it on.
enum StudioSwitch {
    static let defaultsKey = "StudioV2"
    static var headlessValue = false

    static func isOn(for app: AppController) -> Bool {
        app.presentsWindows ? UserDefaults.standard.bool(forKey: defaultsKey) : headlessValue
    }

    static func set(_ on: Bool, for app: AppController) {
        if app.presentsWindows {
            UserDefaults.standard.set(on, forKey: defaultsKey)
        } else {
            headlessValue = on
        }
    }

    /// The hidden item: an Option-alternate of the menu's "About Deskset" (the same key equivalent, Option added), with
    /// a check mark while the new Studio is on.
    static func menuItem(for app: AppController) -> NSMenuItem {
        let item = NSMenuItem(title: StudioText[.useNewStudio],
                              action: #selector(AppController.toggleNewStudioAction(_:)), keyEquivalent: "")
        item.target = app
        item.keyEquivalentModifierMask = [.command, .option]
        item.isAlternate = true
        item.state = isOn(for: app) ? .on : .off
        return item
    }

    /// Puts the hidden item after the menu's "About Deskset" (the item it stands in for while Option is down).
    static func addMenuItem(to menu: NSMenu, for app: AppController) {
        guard let about = menu.items.firstIndex(where: { $0.action == #selector(AppController.aboutAction) }) else {
            return
        }
        let base = menu.items[about]
        let item = menuItem(for: app)
        item.keyEquivalent = base.keyEquivalent
        item.keyEquivalentModifierMask = base.keyEquivalentModifierMask.union(.option)
        menu.insertItem(item, at: about + 1)
    }
}

extension AppController {
    /// "Use New Studio" (the hidden menu item): turns the new Studio window on or off. An open Studio window of the
    /// other kind closes (asking first about code it can't save), so the next "Edit Skin…" opens the one chosen.
    @objc func toggleNewStudioAction(_ sender: Any?) {
        let on = !StudioSwitch.isOn(for: self)
        // The open one closes as closing it would: what waits is written, and typed code it can't save is asked about
        // (Cancel: the switch stays as it was).
        if on {
            if let inspector, !inspector.canTerminate() { return }
            StudioSwitch.set(on, for: self)
            inspector?.window?.close()
        } else {
            if let studio = StudioWindowController.window(for: self), !studio.canTerminate() { return }
            StudioSwitch.set(on, for: self)
            StudioWindowController.window(for: self)?.window?.close()
        }
    }
}
