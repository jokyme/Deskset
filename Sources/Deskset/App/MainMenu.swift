import AppKit

/// The app's main menu. Deskset is a menu bar app (no Dock icon), so the menu bar is rarely visible, but the menu
/// still provides the standard key equivalents (⌘W, ⌘Q, ⌘C/⌘V in text fields…) while the Manage window is active,
/// and becomes visible while the skin editor or Settings is open (`AppActivation`).
///
/// The File, View and Insert commands of the skin editor have no target: they go to the key window's responder chain,
/// where `InspectorWindowController` answers them (and validates them: titles, check marks, enabled state), so they
/// are disabled while another window is in front.
enum MainMenu {
    static func make(app: AppController) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Deskset")
        appMenu.addItem(item("About Deskset", #selector(AppController.aboutAction), target: app))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(AppController.settingsAction), key: ",", target: app))
        let manage = item("Manage Skins…", #selector(AppController.manageAction), key: ",", target: app)
        manage.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(manage)
        appMenu.addItem(item("Install Skin…", #selector(AppController.installSkinAction), target: app))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Deskset", #selector(NSApplication.hide(_:)), key: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Deskset", #selector(NSApplication.terminate(_:)), key: "q"))
        add(appMenu, to: main)

        let file = NSMenu(title: "File")
        file.addItem(item("Save", #selector(InspectorWindowController.saveSkinCode(_:)), key: "s"))
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), key: "z"))
        edit.addItem(item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(findItem("Find…", .showFindInterface, key: "f"))
        find.addItem(findItem("Find and Replace…", .showReplaceInterface, key: "f", modifiers: [.command, .option]))
        find.addItem(findItem("Find Next", .nextMatch, key: "g"))
        find.addItem(findItem("Find Previous", .previousMatch, key: "g", modifiers: [.command, .shift]))
        find.addItem(findItem("Use Selection for Find", .setSearchString, key: "e"))
        find.addItem(item("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), key: "j"))
        let findHolder = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findHolder.submenu = find
        edit.addItem(findHolder)
        add(edit, to: main)

        typealias Editor = InspectorWindowController
        let view = NSMenu(title: "View")
        view.addItem(item("Show Sidebar", #selector(Editor.toggleSidebarPane(_:)), key: "s", modifiers: [.command, .control]))
        view.addItem(item("Show Inspector", #selector(Editor.toggleInspectorPane(_:)), key: "i", modifiers: [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("Design", #selector(Editor.showDesignMode(_:)), key: "1", modifiers: [.command, .control]))
        view.addItem(item("Split", #selector(Editor.showSplitMode(_:)), key: "2", modifiers: [.command, .control]))
        view.addItem(item("Code", #selector(Editor.showCodeMode(_:)), key: "3", modifiers: [.command, .control]))
        view.addItem(item("Show Code", #selector(Editor.toggleCodePane(_:)), key: "\r", modifiers: [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("Code on Right", #selector(Editor.showCodeOnRight(_:))))
        view.addItem(item("Code Below", #selector(Editor.showCodeBelow(_:))))
        view.addItem(.separator())
        view.addItem(item("Zoom In", #selector(Editor.zoomInClicked), key: "+"))
        view.addItem(item("Zoom Out", #selector(Editor.zoomOutClicked), key: "-"))
        view.addItem(item("Actual Size", #selector(Editor.actualSizeClicked), key: "0"))
        view.addItem(item("Zoom to Fit", #selector(Editor.fitClicked), key: "9"))
        view.addItem(.separator())
        // The color behind the widget in the editor (the toolbar's Backdrop ▾, docs/editor-friendly.md §4).
        let backdrop = NSMenu(title: "Canvas Backdrop")
        for b in SkinCanvasView.Backdrop.allCases {
            let i = item(b.title, #selector(Editor.backdropChosen(_:)))
            i.tag = b.rawValue
            backdrop.addItem(i)
        }
        let backdropHolder = NSMenuItem(title: "Canvas Backdrop", action: nil, keyEquivalent: "")
        backdropHolder.submenu = backdrop
        view.addItem(backdropHolder)
        view.addItem(item("Show Content Outside the Widget", #selector(Editor.toggleContentOutside(_:))))
        view.addItem(item("Show Rainmeter Details", #selector(Editor.toggleRainmeterDetails(_:))))
        view.addItem(.separator())
        view.addItem(item("Reload Widget", #selector(Editor.refreshClicked), key: "r"))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f",
                          modifiers: [.command, .control]))
        add(view, to: main)

        let insert = NSMenu(title: "Insert")
        insert.addItem(item("Add…", #selector(Editor.showLibrary(_:)), key: "l", modifiers: [.command, .shift]))
        insert.addItem(.separator())
        for component in Editor.componentMenuItems(target: nil) { insert.addItem(component) }
        add(insert, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        add(window, to: main)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(item("Show Tips Again", #selector(Editor.showTipsAgain(_:))))
        add(help, to: main)
        NSApp.helpMenu = help
        return main
    }

    private static func item(_ title: String, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { i.keyEquivalentModifierMask = modifiers }
        i.target = target
        return i
    }

    /// Edit ▸ Find items: `performFindPanelAction:` with the text finder action as the tag (the code pane's find bar).
    private static func findItem(_ title: String, _ action: NSTextFinder.Action, key: String,
                                 modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = item(title, #selector(NSTextView.performFindPanelAction(_:)), key: key, modifiers: modifiers)
        i.tag = action.rawValue
        return i
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }
}
