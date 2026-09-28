import AppKit
import DesksetCore

/// The menu bar while the new Studio's window is key: File, Edit, Insert, Arrange, View, Widget, Window, Help. Every
/// toolbar item and every command of the window has a menu item (HIG), and no two items share a key. The commands have
/// no target: they go through the responder chain, where the window's controller answers and validates them (titles,
/// check marks, what is enabled). The app's own menu comes back when another window becomes key.
enum StudioMenus {
    /// The menu bar the app had before the Studio took it.
    private static var previous: NSMenu?
    private static weak var installedFor: StudioWindowController?

    /// Each toolbar item and the menu command that does the same.
    static let toolbarCommands: [(item: NSToolbarItem.Identifier, action: Selector)] = [
        (.toggleSidebar, #selector(StudioWindowController.toggleSidebarPane(_:))),
        (.studioTitle, #selector(StudioWindowController.studioShowInFinder(_:))),
        (.studioUndo, #selector(StudioWindowController.undoAction(_:))),
        (.studioRedo, #selector(StudioWindowController.redoAction(_:))),
        (.studioAdd, #selector(StudioWindowController.showLibrary(_:))),
        (.studioCode, #selector(StudioWindowController.showCodeAlongside(_:))),
        (.studioShare, #selector(StudioWindowController.studioShare(_:))),
        (.studioDone, #selector(StudioWindowController.doneAction(_:))),
        // The system's inspector item from macOS 14 (`toggleInspector`), the window's own before.
        (NSToolbarItem.Identifier("NSToolbarToggleInspectorItem"), #selector(StudioWindowController.toggleInspectorPane(_:))),
        (.studioInspector, #selector(StudioWindowController.toggleInspectorPane(_:))),
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
        file.addItem(item(StudioText[.revertToOriginal], #selector(S.studioRevertToOriginal(_:))))
        file.addItem(.separator())
        file.addItem(item(StudioText[.menuShare], #selector(S.studioShare(_:))))
        file.addItem(item(StudioText[.showInFinder], #selector(S.studioShowInFinder(_:))))
        add(file, to: main)

        let edit = NSMenu(title: StudioText[.menuEdit])
        edit.addItem(item(StudioText[.menuUndo], #selector(S.undoAction(_:)), key: "z"))
        edit.addItem(item(StudioText[.menuRedo], #selector(S.redoAction(_:)), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(StudioText[.menuCut], #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item(StudioText[.menuCopy], #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item(StudioText[.menuPaste], #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item(StudioText[.menuDuplicate], #selector(S.studioDuplicate(_:)), key: "d"))
        edit.addItem(item(StudioText[.menuDelete], #selector(S.delete(_:))))
        edit.addItem(item(StudioText[.menuSelectAll], #selector(NSResponder.selectAll(_:)), key: "a"))
        edit.addItem(.separator())
        // The text size, one step (the widget's A− / A+ with nothing selected, the part's with one).
        edit.addItem(item(StudioText[.menuTextBigger], #selector(S.studioTextBigger(_:)), key: "=",
                          modifiers: [.command, .option]))
        edit.addItem(item(StudioText[.menuTextSmaller], #selector(S.studioTextSmaller(_:)), key: "-",
                          modifiers: [.command, .option]))
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

        let insert = NSMenu(title: StudioText[.menuInsert])
        let parts: [(StudioAddCatalog.Part, StudioText.Key)] = [
            (.text, .addText), (.symbol, .addSymbol), (.picture, .addPicture), (.bar, .nounBar), (.ring, .nounRing),
            (.graph, .nounGraph), (.shape, .menuShape), (.button, .addButton),
        ]
        for (part, key) in parts {
            let i = item(capitalized(StudioText[key]), #selector(S.studioInsertPart(_:)))
            i.representedObject = part.rawValue
            insert.addItem(i)
        }
        insert.addItem(.separator())
        insert.addItem(item(StudioText[.menuData], #selector(S.studioInsertData(_:))))
        add(insert, to: main)

        let arrange = NSMenu(title: StudioText[.menuArrange])
        arrange.addItem(item(StudioText[.axBringForward], #selector(S.studioBringForward(_:))))
        arrange.addItem(item(StudioText[.axSendBackward], #selector(S.studioSendBackward(_:))))
        arrange.addItem(.separator())
        let align = NSMenu(title: StudioText[.menuAlign])
        // With nothing selected (or the widget itself) Align says where lining up widgets is done.
        let hint = item(StudioText[.alignWidgetsHint], #selector(S.studioArrangeWidgetsHint(_:)))
        hint.tag = -1
        align.addItem(hint)
        let modes: [(EditorAlign.Mode, StudioText.Key)] = [
            (.left, .alignLeftEdges), (.centerX, .alignCenterX), (.right, .alignRightEdges),
            (.top, .alignTop), (.centerY, .alignCenterY), (.bottom, .alignBottom),
        ]
        for (index, (mode, key)) in modes.enumerated() {
            if index == 3 { align.addItem(.separator()) }
            let i = item(StudioText[key], #selector(S.studioAlign(_:)))
            i.representedObject = mode.rawValue
            align.addItem(i)
        }
        arrange.addItem(holder(align))
        let distribute = NSMenu(title: StudioText[.menuDistribute])
        for (mode, key) in [(EditorAlign.Mode.distributeX, StudioText.Key.distributeX), (.distributeY, .distributeY)] {
            let i = item(StudioText[key], #selector(S.studioAlign(_:)))
            i.representedObject = mode.rawValue
            distribute.addItem(i)
        }
        arrange.addItem(holder(distribute))
        arrange.addItem(.separator())
        arrange.addItem(item(StudioText[.layerLock], #selector(S.studioLock(_:))))
        arrange.addItem(item(StudioText[.layerHide], #selector(S.studioHide(_:))))
        arrange.addItem(.separator())
        arrange.addItem(item(StudioText[.arrangeWidgets], #selector(S.studioArrangeWidgets(_:))))
        add(arrange, to: main)

        let view = NSMenu(title: StudioText[.menuView])
        view.addItem(item(StudioText[.menuShowAdd], #selector(S.showLibrary(_:)), key: "l", modifiers: [.command, .shift]))
        view.addItem(item(StudioText[.menuShowLayers], #selector(S.showLayers(_:)), key: "l",
                          modifiers: [.command, .option]))
        view.addItem(item(StudioText[.showSidebar], #selector(S.toggleSidebarPane(_:)), key: "s",
                          modifiers: [.command, .control]))
        view.addItem(item(StudioText[.showInspector], #selector(S.toggleInspectorPane(_:)), key: "i",
                          modifiers: [.command, .option]))
        view.addItem(.separator())
        view.addItem(item(StudioText[.menuDesignOnly], #selector(S.showDesignOnly(_:)), key: "1",
                          modifiers: [.command, .control]))
        view.addItem(item(StudioText[.menuCodeAlongside], #selector(S.showCodeAlongside(_:)), key: "2",
                          modifiers: [.command, .control]))
        view.addItem(item(StudioText[.menuCodeOnly], #selector(S.showCodeOnly(_:)), key: "3",
                          modifiers: [.command, .control]))
        view.addItem(item(StudioText[.menuShowInCode], #selector(S.showInCode(_:)), key: "\r",
                          modifiers: [.command, .option]))
        view.addItem(item(StudioText[.menuEverySetting], #selector(S.studioEverySetting(_:)), key: "e",
                          modifiers: [.command, .option]))
        view.addItem(.separator())
        view.addItem(item(StudioText[.zoomIn], #selector(S.zoomInClicked), key: "+"))
        view.addItem(item(StudioText[.zoomOut], #selector(S.zoomOutClicked), key: "-"))
        view.addItem(item(StudioText[.actualSize], #selector(S.actualSizeClicked), key: "0"))
        view.addItem(item(StudioText[.zoomToFit], #selector(S.fitClicked), key: "9"))
        view.addItem(item(StudioText[.zoomToSelection], #selector(S.studioZoomToSelection(_:)), key: "9",
                          modifiers: [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item(StudioText[.showOnDesktop], #selector(S.showOnDesktop(_:)), key: "d",
                          modifiers: [.command, .shift]))
        view.addItem(item(StudioText[.menuRainmeterDetails], #selector(S.toggleRainmeterDetails(_:)), key: "r",
                          modifiers: [.command, .option]))
        view.addItem(.separator())
        view.addItem(item(StudioText[.menuFullScreen], #selector(NSWindow.toggleFullScreen(_:)), key: "f",
                          modifiers: [.command, .control]))
        add(view, to: main)

        let widget = NSMenu(title: StudioText[.menuWidget])
        widget.addItem(item(StudioText[.menuRefresh], #selector(S.studioRefresh(_:)), key: "r"))
        widget.addItem(item(StudioText[.interact], #selector(S.toggleInteract(_:)), key: "p",
                            modifiers: [.command, .option]))
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
        if let window = menu.items.first(where: { $0.submenu?.title == "Window" })?.submenu { NSApp.windowsMenu = window }
        if let help = menu.items.first(where: { $0.submenu?.title == "Help" })?.submenu { NSApp.helpMenu = help }
    }

    /// Every item of `menu` and its submenus.
    static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
    }

    private static func capitalized(_ s: String) -> String {
        StudioText.language == .chinese ? s : s.prefix(1).uppercased() + s.dropFirst()
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

    /// Sharing comes later: the item is there, and off.
    @objc func studioShare(_ sender: Any?) {}

    /// File ▸ Show in Finder: the file the code shows, else the widget's main file.
    @objc func studioShowInFinder(_ sender: Any?) {
        if isCodeShown { showCodeFileInFinder() } else { link?.showInFinder() }
    }

    /// ⌘D: a copy of each selected part, 10 points right and down so it shows, at the end of the widget's file (as
    /// the old Studio makes it): one step, the copies selected.
    @objc func studioDuplicate(_ sender: Any?) {
        guard let skin else { return }
        let names = canvasController.canvas.selectedNames.filter { skin.meter(named: $0) != nil }
        guard !names.isEmpty else { return }
        var taken = skin.sectionNames
        let sections = names.compactMap { skin.duplicateSections($0, dx: 10, dy: 10, taken: &taken) }
        guard !sections.isEmpty else { return }
        let title = names.count == 1 ? skin.meter(named: names[0]).map { partPage.partTitle($0, skin: skin) } ?? names[0]
            : StudioText.format(.partsCount, names.count)
        let step = StudioText[.stepDuplicate]
        pendingAnnouncement = StudioText.format(.confirmAdded, title)
        guard partPage.apply(step, [skin.op(appending: sections)]) else { return }
        refreshLayers()
        let copies = sections.map(\.name).filter { self.skin?.meter(named: $0) != nil }
        if copies.count == 1 {
            select(part: copies[0])
        } else if !copies.isEmpty {
            canvasController.canvas.setSelection(names: copies)
            selectionChanged(copies)
        }
    }

    /// Delete: the selected parts, as one step (parts a file other widgets share defines stay, and the page says so).
    @objc func delete(_ sender: Any?) {
        deleteParts(canvasController.canvas.selectedNames)
    }

    /// ⌘A on the canvas: every part.
    override func selectAll(_ sender: Any?) {
        canvasController.canvas.selectAll()
        selectionChanged(canvasController.canvas.selectedNames)
    }

    /// ⌘F: "What do you want to change?" (in S2a the inspector's field, which filters Every Setting); in the code
    /// (when it has the keyboard or took the inspector's place) its find bar.
    @objc func studioFind(_ sender: Any?) {
        if isCodeShown, focusArea == .code || inspectorItem.isCollapsed {
            window?.makeFirstResponder(codeView.textView)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            codeView.textView.performFindPanelAction(item)
            return
        }
        setInspectorShown(true)
        window?.makeFirstResponder(inspectorController.pageView.searchField)
    }

    @objc func studioInsertPart(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let part = StudioAddCatalog.Part(rawValue: raw) else { return }
        _ = addPart(part)
    }

    /// Insert ▸ Data…: the Add page, its search field ready.
    @objc func studioInsertData(_ sender: Any?) {
        showSidebarPage(.add)
        window?.makeFirstResponder(sidebarController.addView.searchField)
    }

    @objc func studioBringForward(_ sender: Any?) {
        guard let name = canvasController.canvas.selectedNames.last else { return }
        _ = bringForward(name)
    }

    @objc func studioSendBackward(_ sender: Any?) {
        guard let name = canvasController.canvas.selectedNames.last else { return }
        _ = sendBackward(name)
    }

    @objc func studioLock(_ sender: Any?) {
        for name in canvasController.canvas.selectedNames { toggleLock(name) }
    }

    @objc func studioHide(_ sender: Any?) {
        guard let name = canvasController.canvas.selectedNames.last else { return }
        hide(part: name)
    }

    /// Align and Distribute: the selected parts' frames (one part: to the widget), written as one step keeping how
    /// each X and Y is written.
    @objc func studioAlign(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let mode = EditorAlign.Mode(rawValue: raw),
              let skin else { return }
        let names = canvasController.canvas.selectedNames
        let meters = names.compactMap { skin.meter(named: $0) }
        guard !meters.isEmpty else { return }
        let whole = SkinRect(x: 0, y: 0, width: skin.width, height: skin.height)
        guard let frames = EditorAlign.frames(meters.map(\.frame), mode: mode, skin: whole) else { return }
        geometry.begin(meters.map(\.name), resize: false)
        var targets: [String: SkinRect] = [:]
        for (m, f) in zip(meters, frames) { targets[m.name] = f }
        geometry.preview(targets)
        geometry.end(keep: true)
    }

    /// The hint in Align while nothing is selected: lining up widgets is Arrange Widgets', which is not there yet —
    /// the hint says so (instead of greying out).
    @objc func studioArrangeWidgetsHint(_ sender: Any?) {
        widgetPage.showTop(.init(text: StudioText[.arrangeWidgetsLater], undo: ""))
        announce(StudioText[.arrangeWidgetsLater])
    }

    /// ⌥⌘= / ⌥⌘−: one step of text size — every text of the widget with nothing selected (A− / A+ of its page), the
    /// selected text's own size with one (A− / A+ of the part's page).
    @objc func studioTextBigger(_ sender: Any?) { stepText(1) }
    @objc func studioTextSmaller(_ sender: Any?) { stepText(-1) }

    func stepText(_ step: Int) {
        if let name = canvasController.canvas.selectedNames.last, skin?.meter(named: name) is StringMeter {
            if partPage.focus == nil || partPage.meter?.name.caseInsensitiveCompare(name) != .orderedSame {
                select(part: name)
            }
            partPage.number("text.size", part: 0, .textStep(step))
        } else {
            widgetPage.scaleText(step)
        }
    }

    /// Whether ⌥⌘= / ⌥⌘− has text to change.
    var canStepText: Bool {
        guard let skin else { return false }
        if let name = canvasController.canvas.selectedNames.last { return skin.meter(named: name) is StringMeter }
        return !(widgetPage.facts?.textSizes.isEmpty ?? true)
    }

    /// File ▸ Revert to Original: the widget page's footer command.
    @objc func studioRevertToOriginal(_ sender: Any?) { widgetPage.revertToOriginal() }

    /// ⇧⌘9: the selection fills the canvas.
    @objc func studioZoomToSelection(_ sender: Any?) { preview.zoomToSelection() }
    @objc func studioArrangeWidgets(_ sender: Any?) {}

    @objc func showDesignOnly(_ sender: Any?) { setCodeMode(.hidden) }
    @objc func showCodeAlongside(_ sender: Any?) { setCodeMode(.alongside) }
    @objc func showCodeOnly(_ sender: Any?) { setCodeMode(.only) }

    /// ⌥⌘E: Every Setting of the selected part.
    @objc func studioEverySetting(_ sender: Any?) { partPage.toggleEverySetting() }

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
        let selected = canvasController.canvas.selectedNames
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
        case #selector(studioShare(_:))?, #selector(studioArrangeWidgets(_:))?:
            return false
        case #selector(studioArrangeWidgetsHint(_:))?:
            item.isHidden = !selected.isEmpty
            return true
        case #selector(studioTextBigger(_:))?, #selector(studioTextSmaller(_:))?:
            return canStepText
        case #selector(studioRevertToOriginal(_:))?:
            let link = widgetPage.revertLink()
            item.title = link.map { StudioText.format(.menuRevertCount, $0.detail ?? "") } ?? StudioText[.revertToOriginal]
            return link != nil
        case #selector(studioZoomToSelection(_:))?:
            return !selected.isEmpty
        case #selector(studioAlign(_:))?:
            let mode = (item.representedObject as? String).flatMap(EditorAlign.Mode.init(rawValue:))
            if mode == .distributeX || mode == .distributeY { return selected.count >= 3 }
            return !selected.isEmpty
        case #selector(studioDuplicate(_:))?, #selector(delete(_:))?, #selector(studioBringForward(_:))?,
             #selector(studioSendBackward(_:))?, #selector(studioLock(_:))?, #selector(studioHide(_:))?,
             #selector(studioEverySetting(_:))?:
            return !selected.isEmpty
        case #selector(selectAll(_:))?:
            return skin != nil
        case #selector(showDesignOnly(_:))?:
            item.state = codeState.mode == .hidden ? .on : .off
            return true
        case #selector(showCodeAlongside(_:))?:
            item.state = codeState.mode == .alongside ? .on : .off
            return skin != nil
        case #selector(showCodeOnly(_:))?:
            item.state = codeState.mode == .only ? .on : .off
            return skin != nil
        case #selector(toggleInspectorPane(_:))?:
            item.title = inspectorItem.isCollapsed ? StudioText[.showInspector] : StudioText[.hideInspector]
            return true
        case #selector(toggleInteract(_:))?:
            item.state = preview.state.interacting ? .on : .off
            return skin != nil
        case #selector(showOnDesktop(_:))?:
            item.state = preview.desktopView.isShowing ? .on : .off
            return link?.isOnDesktop ?? false
        case #selector(studioInsertPart(_:))?, #selector(studioInsertData(_:))?, #selector(studioRefresh(_:))?,
             #selector(showInCode(_:))?, #selector(showWidgetLog(_:))?:
            return skin != nil
        default:
            return nil
        }
    }
}
