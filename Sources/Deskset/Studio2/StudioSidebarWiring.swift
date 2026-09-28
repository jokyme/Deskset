import AppKit
import DesksetCore

/// What the window keeps about its sidebar and the keyboard's route.
final class StudioSidebarState {
    /// What is typed in "Find a layer".
    var filter = ""
    /// The hint at the sidebar's foot (or over the canvas while the sidebar is closed).
    var hint: String?
    /// Refreshes the Layers list's live values while it shows.
    var liveTimer: Timer?
    /// Return moved the focus from the canvas to the inspector: Esc there brings it back to the part.
    var focusFromCanvas = false
}

/// The sidebar in the window: the Layers list follows the Studio's instance and the canvas's selection, and carries
/// out what is done in it; Rainmeter details (⌥⌘R); the keyboard's route between the panes (⌃Tab).
extension StudioWindowController {
    /// The widget is a Rainmeter skin (compatibility mode: its own .ini files are edited).
    var isRainmeterSkin: Bool {
        guard let link else { return false }
        if case .rainmeter = link.provenance { return true }
        return false
    }

    /// The tip id that says the first Rainmeter skin turned Rainmeter details on (kept in the Studio's settings).
    static let rainmeterNamesTip = "studio2.rainmeterNames"

    func wireSidebar() {
        _ = sidebarController.view
        sidebarController.layersView.onEvent = { [weak self] event in self?.layersEvent(event) }
        sidebarController.onPageChange = { [weak self] _ in
            self?.updateToolbar()
            self?.refreshLayers()
        }
        let canvas = canvasController.canvas
        canvas.isLocked = { [weak self] name in self?.lockedParts.contains(name.lowercased()) ?? false }
        canvas.onDelete = { [weak self] in
            guard let self, let name = self.canvasController.canvas.selectedNames.last else { return }
            self.delete(part: name)
        }
        canvasController.compatState = { [weak self] in
            guard let self, let session = self.session, self.isRainmeterSkin else {
                return (false, false)
            }
            let stayed = self.app.state.editor.seenTips.contains(StudioCompatChoice.tip(session.config))
            return (true, !stayed && !session.undoStack.canUndo)
        }
        canvasController.compatCapsule.onStay = { [weak self] in self?.stayWithINI() }
    }

    /// Stay with INI: the offer goes for this skin, remembered.
    func stayWithINI() {
        guard let config = session?.config else { return }
        app.state.updateEditor { $0.seenTips.insert(StudioCompatChoice.tip(config)) }
        canvasController.updateCompatCapsule()
    }

    // MARK: The Layers list

    /// Works the Layers list out again from the Studio's instance (rows that stay are updated in place), and the
    /// canvas's accessibility elements with it.
    func refreshLayers() {
        guard let skin else { return }
        let lists = StudioLayersModel.lists(skin: skin, widgetName: widgetName, details: showsRainmeterDetails,
                                            filter: sidebarState.filter, locked: lockedParts)
        let layers = sidebarController.layersView
        layers.show(lists, details: showsRainmeterDetails)
        syncLayersSelection()
        canvasAccess.rebuild()
    }

    /// The Layers list selects what the canvas and the inspector show.
    func syncLayersSelection() {
        let layers = sidebarController.layersView
        if case .data(let name)? = partPage.focus {
            layers.select(data: name)
        } else {
            layers.select(parts: canvasController.canvas.selectedNames)
        }
    }

    /// Keeps the list's values live while the sidebar shows (once a second; the canvas follows the widget's rate).
    func startLayersTimer() {
        sidebarState.liveTimer?.invalidate()
        guard app.presentsWindows else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true, self.skin != nil else { return }
            if !self.sidebarItem.isCollapsed, self.sidebarController.page == .layers { self.refreshLayers() }
            else { self.canvasAccess.refreshValues() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        sidebarState.liveTimer = timer
    }

    func layersEvent(_ event: StudioLayersEvent) {
        switch event {
        case .selectPart(let name):
            select(part: name)
            if name == nil { sidebarController.layersView.select(parts: [], widget: true) }
        case .selectData(let name):
            canvasController.canvas.setSelection(nil)
            partPage.show(data: name)
            showDataUsers(name)
        case .hoverData(let name):
            if let name { showDataUsers(name) } else if case .data(let selected)? = partPage.focus {
                showDataUsers(selected)
            } else {
                canvasController.overlay.showFrames(nil)
                sidebarController.layersView.outline(parts: [])
            }
        case .toggleHidden(let name):
            toggleHidden(name)
        case .toggleLock(let name):
            toggleLock(name)
        case .move(let names, let before):
            moveParts(names, before: before)
        case .delete(let name):
            delete(part: name)
        case .filter(let text):
            sidebarState.filter = text
            refreshLayers()
        }
    }

    /// Outlines on the canvas (and in the list) the parts that show a data item, tagged "MeasureCPU · used by 2 parts".
    func showDataUsers(_ name: String) {
        guard let skin, let measure = skin.measure(named: name) else { return }
        let users = StudioLayersModel.users(of: measure, in: skin).map(\.name)
        let label = showsRainmeterDetails ? measure.name : StudioPartNames.dataName(measure, in: skin)
        let tag = users.isEmpty ? StudioText.format(.dataUnusedTag, label)
            : StudioText.format(.dataUsedByTag, label, StudioWords.parts(users.count))
        canvasController.overlay.showFrames(.init(names: users, tag: tag, ink: StudioCanvasOverlay.ink(for: skin)))
        sidebarController.layersView.outline(parts: users)
    }

    // MARK: Showing the sidebar

    /// ⌃⌘S (View ▸ Show Sidebar): the sidebar opens (Build) or closes (Customize).
    @objc func toggleSidebarPane(_ sender: Any?) {
        setSidebarOpen(sidebarItem.isCollapsed)
        if !sidebarItem.isCollapsed { refreshLayers() }
    }

    /// ⇧⌘L (Insert ▸ Add…): the sidebar on its Add page, the cursor in its search field.
    @objc func showLibrary(_ sender: Any?) {
        showSidebarPage(.add)
        if app.presentsWindows { window?.makeFirstResponder(sidebarController.addView.searchField) }
    }

    /// ⌥⌘L: the sidebar on its Layers page.
    @objc func showLayers(_ sender: Any?) {
        showSidebarPage(.layers)
        if app.presentsWindows { window?.makeFirstResponder(sidebarController.layersView.partsOutline) }
    }

    func showSidebarPage(_ page: StudioSidebarViewController.Page) {
        sidebarController.show(page)
        setSidebarOpen(true)
        refreshLayers()
        updateToolbar()
    }

    // MARK: Rainmeter details

    /// Show Rainmeter Details (⌥⌘R): the INI key names beside the inspector's rows, the meter names under the layers,
    /// the data group as "Measures". Remembered for the user (the Studio's settings).
    var showsRainmeterDetails: Bool { app.state.editor.showIniNames }

    @objc func toggleRainmeterDetails(_ sender: Any?) {
        app.state.updateEditor { $0.showIniNames.toggle() }
        rainmeterDetailsChanged()
        announce(showsRainmeterDetails ? StudioText[.rainmeterNamesShown] : StudioText[.rainmeterNamesHidden])
    }

    /// The pages and the list follow a change of Rainmeter details; the first-time hint goes.
    func rainmeterDetailsChanged() {
        setHint(nil)
        widgetPage.refresh()
        partPage.refresh()
        refreshLayers()
        if case .data(let name)? = partPage.focus { showDataUsers(name) }
    }

    /// The first time a Rainmeter skin opens in the Studio, Rainmeter details turn on, with a hint that says how to
    /// hide them. Once per user.
    func turnOnRainmeterDetailsTheFirstTime() {
        guard isRainmeterSkin, !app.state.editor.seenTips.contains(Self.rainmeterNamesTip) else { return }
        app.state.updateEditor { e in
            e.showIniNames = true
            e.seenTips.insert(Self.rainmeterNamesTip)
        }
        setHint(StudioText[.rainmeterNamesOn])
    }

    /// The hint at the sidebar's foot, or over the canvas's corner while the sidebar is closed.
    func setHint(_ text: String?) {
        sidebarState.hint = text
        placeHint()
    }

    func placeHint() {
        let text = sidebarState.hint
        sidebarController.setHint(sidebarItem.isCollapsed ? nil : text)
        canvasController.setHint(sidebarItem.isCollapsed ? text : nil)
    }

    // MARK: Menus

    func validateStudioMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(toggleRainmeterDetails(_:))?:
            item.state = showsRainmeterDetails ? .on : .off
            return true
        case #selector(toggleSidebarPane(_:))?:
            item.title = sidebarItem.isCollapsed ? StudioText[.showSidebar] : StudioText[.hideSidebar]
            return true
        case #selector(showLibrary(_:))?, #selector(showLayers(_:))?:
            return skin != nil
        default:
            return nil
        }
    }

    // MARK: Keys

    /// The window's own keys: ⌥⌘R Rainmeter details, ⌥⌘L Layers, ⌃⌘S the sidebar, ⇧⌘L Add.
    func sidebarKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case ([.command, .option], "r"), ([.command, .option], "®"):
            toggleRainmeterDetails(nil)
        case ([.command, .option], "l"), ([.command, .option], "¬"):
            showLayers(nil)
        case ([.command, .control], "s"):
            toggleSidebarPane(nil)
        case ([.command, .shift], "l"):
            showLibrary(nil)
        default:
            return false
        }
        return true
    }

    // MARK: The keyboard's route

    enum FocusArea: Int, CaseIterable { case canvas, inspector, code, sidebar }

    /// The pane the keyboard is in.
    var focusArea: FocusArea? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        if responder.isDescendant(of: canvasController.view) { return .canvas }
        if responder.isDescendant(of: inspectorController.view) { return .inspector }
        if !sidebarItem.isCollapsed, responder.isDescendant(of: sidebarController.view) { return .sidebar }
        // A field editor belongs to the field it edits.
        if let text = responder as? NSTextView, text.isFieldEditor, let field = text.delegate as? NSView {
            if field.isDescendant(of: inspectorController.view) { return .inspector }
            if field.isDescendant(of: sidebarController.view) { return .sidebar }
        }
        return nil
    }

    /// The panes the route goes through now: the canvas, the inspector (when shown), the code (when shown: a later
    /// step), the sidebar (when open).
    var focusAreas: [FocusArea] {
        FocusArea.allCases.filter { area in
            switch area {
            case .canvas: return true
            case .inspector: return !inspectorItem.isCollapsed
            case .code: return false
            case .sidebar: return !sidebarItem.isCollapsed
            }
        }
    }

    /// ⌃Tab / ⌃⇧Tab: the next (or previous) pane.
    func cycleFocus(backward: Bool) {
        let areas = focusAreas
        let current = focusArea.flatMap { areas.firstIndex(of: $0) }
        let next: Int
        if let current { next = (current + (backward ? areas.count - 1 : 1)) % areas.count } else { next = 0 }
        focus(areas[next])
    }

    func focus(_ area: FocusArea) {
        sidebarState.focusFromCanvas = false
        switch area {
        case .canvas:
            window?.makeFirstResponder(canvasController.canvas)
        case .inspector:
            focusInspector()
        case .code:
            break
        case .sidebar:
            if sidebarController.page == .layers {
                window?.makeFirstResponder(sidebarController.layersView.partsOutline)
            } else {
                window?.makeFirstResponder(sidebarController.addView.searchField)
            }
        }
    }

    /// The first control of the inspector's page (its search field when the page has none).
    func focusInspector() {
        _ = inspectorController.view
        let target = Self.firstKeyView(in: inspectorController.pageView) ?? inspectorController.pageView
        window?.makeFirstResponder(target)
    }

    /// The first view under `root` that takes the keyboard, top to bottom, left to right.
    static func firstKeyView(in root: NSView) -> NSView? {
        var found: [(NSView, NSPoint)] = []
        func walk(_ v: NSView) {
            if v.isHiddenOrHasHiddenAncestor { return }
            if v !== root, v.acceptsFirstResponder, v is NSControl {
                found.append((v, v.convert(NSPoint.zero, to: root)))
                return
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        let flipped = root.isFlipped
        return found.min { a, b in
            let ya = flipped ? a.1.y : -a.1.y, yb = flipped ? b.1.y : -b.1.y
            return abs(ya - yb) > 2 ? ya < yb : a.1.x < b.1.x
        }?.0
    }

    /// Return on the canvas with a part selected: the keyboard goes to its page's first control; Esc there comes back.
    func returnFromCanvas() -> Bool {
        guard !canvasController.canvas.selectedNames.isEmpty else { return false }
        focusInspector()
        sidebarState.focusFromCanvas = true
        return true
    }

    /// Esc in the inspector: back to the part on the canvas when Return brought the keyboard there, else one level up.
    func escapeFromInspector() {
        if sidebarState.focusFromCanvas, !canvasController.canvas.selectedNames.isEmpty {
            sidebarState.focusFromCanvas = false
            window?.makeFirstResponder(canvasController.canvas)
            return
        }
        sidebarState.focusFromCanvas = false
        goUp()
    }
}
