import AppKit
import DesksetCore

/// The menu bar while the Studio's window is key: File, Edit, View, Widget, Window, Help. Every toolbar item and every
/// command of the window has a menu item (HIG), and no two items share a key. The commands have no target: they go
/// through the responder chain, where the window's controller answers and validates them. The app's own menu comes
/// back when another window becomes key.
enum StudioMenus {
    /// The menu bar the app had before the Studio took it.
    private static var previous: NSMenu?
    private static weak var installedFor: StudioWindowController?

    /// Each toolbar item and the menu command that does the same.
    static let toolbarCommands: [(item: NSToolbarItem.Identifier, action: Selector)] = [
        (.studioTitle, #selector(StudioWindowController.studioShowInFinder(_:))),
        (.studioDone, #selector(StudioWindowController.doneAction(_:))),
    ]

    /// The Studio's menu bar.
    static func make(app: AppController) -> NSMenu {
        typealias S = StudioWindowController
        let main = NSMenu()

        let appMenu = NSMenu(title: "Deskset")
        appMenu.addItem(item(StudioText[.menuAbout], #selector(AppController.aboutAction), target: app))
        appMenu.addItem(.separator())
        appMenu.addItem(item(StudioText[.menuSettings], #selector(AppController.settingsAction), key: ",", target: app))
        appMenu.addItem(.separator())
        appMenu.addItem(item(StudioText[.appMenuHide], #selector(NSApplication.hide(_:)), key: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(item(StudioText[.menuQuit], #selector(NSApplication.terminate(_:)), key: "q"))
        add(appMenu, to: main)

        let file = NSMenu(title: StudioText[.menuFile])
        file.addItem(item(StudioText[.menuClose], #selector(NSWindow.performClose(_:)), key: "w"))
        file.addItem(item(StudioText[.menuSave], #selector(S.studioSave(_:)), key: "s"))
        file.addItem(.separator())
        file.addItem(item(StudioText[.showInFinder], #selector(S.studioShowInFinder(_:))))
        add(file, to: main)

        let edit = NSMenu(title: StudioText[.menuEdit])
        edit.addItem(item(StudioText[.menuUndo], #selector(S.undoAction(_:)), key: "z"))
        edit.addItem(item(StudioText[.menuRedo], #selector(S.redoAction(_:)), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(StudioText[.menuCut], #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item(StudioText[.menuCopy], #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item(StudioText[.menuPaste], #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item(StudioText[.menuSelectAll], #selector(NSResponder.selectAll(_:)), key: "a"))
        edit.addItem(.separator())
        let find = NSMenu(title: StudioText[.menuFind])
        find.addItem(item(StudioText[.menuFindChange], #selector(S.studioFind(_:)), key: "f"))
        let next = item(StudioText[.menuFindNext], #selector(NSTextView.performFindPanelAction(_:)), key: "g")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        find.addItem(next)
        let previous = item(StudioText[.menuFindPrevious], #selector(NSTextView.performFindPanelAction(_:)), key: "g",
                            modifiers: [.command, .shift])
        previous.tag = NSTextFinder.Action.previousMatch.rawValue
        find.addItem(previous)
        edit.addItem(holder(find))
        add(edit, to: main)

        let view = NSMenu(title: StudioText[.menuView])
        view.addItem(item(StudioText[.menuCodeAlongside], #selector(S.showCodeAlongside(_:)), key: "2",
                          modifiers: [.command, .control]))
        view.addItem(item(StudioText[.menuCodeOnly], #selector(S.showCodeOnly(_:)), key: "3",
                          modifiers: [.command, .control]))
        view.addItem(.separator())
        view.addItem(item(StudioText[.zoomIn], #selector(S.zoomInClicked), key: "+"))
        view.addItem(item(StudioText[.zoomOut], #selector(S.zoomOutClicked), key: "-"))
        view.addItem(item(StudioText[.actualSize], #selector(S.actualSizeClicked), key: "0"))
        view.addItem(item(StudioText[.zoomToFit], #selector(S.fitClicked), key: "9"))
        view.addItem(.separator())
        view.addItem(item(StudioText[.menuFullScreen], #selector(NSWindow.toggleFullScreen(_:)), key: "f",
                          modifiers: [.command, .control]))
        add(view, to: main)

        let widget = NSMenu(title: StudioText[.menuWidget])
        widget.addItem(item(StudioText[.menuRefresh], #selector(S.studioRefresh(_:)), key: "r"))
        widget.addItem(item(StudioText[.menuPreviewOptions], #selector(S.studioPreviewOptions(_:)), key: "o",
                            modifiers: [.command, .option]))
        widget.addItem(.separator())
        widget.addItem(item(StudioText[.done], #selector(S.doneAction(_:)), key: "\r"))
        add(widget, to: main)

        let window = NSMenu(title: StudioText[.menuWindow])
        window.addItem(item(StudioText[.menuMinimize], #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item(StudioText[.menuZoomWindow], #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        let log = NSMenu(title: StudioText[.menuLog])
        log.addItem(item(StudioText[.logThisWidget], #selector(S.showWidgetLog(_:))))
        log.addItem(item(StudioText[.logAllWidgets], #selector(S.showAllLogs(_:))))
        window.addItem(holder(log))
        add(window, to: main)

        let help = NSMenu(title: StudioText[.menuHelp])
        add(help, to: main)
        return main
    }

    /// Takes the menu bar for `studio` (its window became key).
    static func install(for studio: StudioWindowController) {
        guard studio.app.presentsWindows else { return }
        if installedFor == nil { previous = NSApp.mainMenu }
        installedFor = studio
        let menu = make(app: studio.app)
        NSApp.mainMenu = menu
        if let window = menu.items.first(where: { $0.submenu?.title == StudioText[.menuWindow] })?.submenu {
            NSApp.windowsMenu = window
        }
        if let help = menu.items.last?.submenu { NSApp.helpMenu = help }
    }

    /// Gives the menu bar back (the window is no longer key, or closes).
    static func restore(for studio: StudioWindowController) {
        guard installedFor === studio else { return }
        installedFor = nil
        let menu = previous ?? MainMenu.make(app: studio.app)
        previous = nil
        NSApp.mainMenu = menu
        if let window = menu.items.first(where: { $0.submenu?.title == L("Window") })?.submenu { NSApp.windowsMenu = window }
        if let help = menu.items.first(where: { $0.submenu?.title == L("Help") })?.submenu { NSApp.helpMenu = help }
    }

    /// Every item of `menu` and its submenus.
    static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
    }

    private static func item(_ title: String, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { i.keyEquivalentModifierMask = modifiers }
        i.target = target
        return i
    }

    private static func holder(_ menu: NSMenu) -> NSMenuItem {
        let h = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        h.submenu = menu
        return h
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        main.addItem(holder(menu))
    }
}

// MARK: - The commands

extension StudioWindowController {
    /// ⌘S: typed code is committed (every other step is written as it is made).
    @objc func studioSave(_ sender: Any?) {
        if codeController.isViewLoaded { codeView.commitNow(explicit: true) }
        flush()
        updateCodeStatus()
    }

    /// File ▸ Show in Finder: the file the code shows, else the widget's main file.
    @objc func studioShowInFinder(_ sender: Any?) {
        if isCodeShown { showCodeFileInFinder() } else { link?.showInFinder() }
    }

    /// ⌘F: opens the code pane's find bar.
    @objc func studioFind(_ sender: Any?) {
        window?.makeFirstResponder(codeView.textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        codeView.textView.performFindPanelAction(item)
    }

    @objc func showCodeAlongside(_ sender: Any?) { setCodeMode(.alongside) }
    @objc func showCodeOnly(_ sender: Any?) { setCodeMode(.only) }

    /// ⌘R: the widget read again from its files — its OnRefreshAction runs, its variables start over — here and on the
    /// desktop (unless the desktop keeps the last working version).
    @objc func studioRefresh(_ sender: Any?) {
        guard let session else { return }
        flushCode()
        session.takeChangesFromDisk()
        session.reloadStudioSkin()
        session.scheduleDesktopRefresh()
        releaseOthers()
        refreshDiagnostics()
    }

    /// ⌥⌘O: the preview's options.
    @objc func studioPreviewOptions(_ sender: Any?) { preview.showPreviewPopover() }

    /// Titles, check marks and what is enabled, for the Studio's own commands (nil: not one of them).
    func validateMenusItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(undoAction(_:))?:
            if focusArea == .code, let text = codeView.textView.undoManager, text.canUndo {
                item.title = text.undoMenuItemTitle
                return true
            }
            let undo = session?.undoStack
            item.title = (undo?.canUndo ?? false) && !(undo?.undoActionName.isEmpty ?? true)
                ? StudioText.format(.undoNamed, undo!.undoActionName) : StudioText[.menuUndo]
            return undo?.canUndo ?? false
        case #selector(redoAction(_:))?:
            if focusArea == .code, let text = codeView.textView.undoManager, text.canRedo {
                item.title = text.redoMenuItemTitle
                return true
            }
            let undo = session?.undoStack
            item.title = (undo?.canRedo ?? false) && !(undo?.redoActionName.isEmpty ?? true)
                ? StudioText.format(.redoNamed, undo!.redoActionName) : StudioText[.menuRedo]
            return undo?.canRedo ?? false
        case #selector(showCodeAlongside(_:))?:
            item.state = codeState.mode == .alongside ? .on : .off
            return skin != nil
        case #selector(showCodeOnly(_:))?:
            item.state = codeState.mode == .only ? .on : .off
            return skin != nil
        case #selector(studioRefresh(_:))?, #selector(showWidgetLog(_:))?:
            return skin != nil
        default:
            return nil
        }
    }
}
