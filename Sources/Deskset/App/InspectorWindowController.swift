import AppKit
import DesksetCore

/// The skin editor ("skin studio", docs/editor-design.md §1). Three panes that can each be hidden: a sidebar
/// (component Library, Layers, Data), the centre — itself split into a zoomable canvas where meters are selected,
/// dragged, resized and nudged, and the built-in code editor showing the skin's files — and an inspector of cards for
/// the selection. The mode control (Design | Split | Code) only decides what the centre shows.
///
/// Every change goes the same way: a live preview while the user drags or picks a color (`Skin.preview`), then one
/// write to the file that defines the value (geometry always to the meter's own section), one undo step (the bytes
/// of the changed files, see `EditorFileChange`) and a refresh of the skin. Typed code is one more such change: the
/// code pane commits its buffer through the same pipeline ("Edit Code"), and a dirty buffer is committed before any
/// visual edit writes, so the files on disk stay the single source of truth. Files saved in another editor refresh
/// the skin too. The skin on the desktop keeps working normally.
final class InspectorWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSToolbarDelegate,
                                       NSMenuItemValidation, NSToolbarItemValidation, NSSplitViewDelegate {

    /// A layer-list entry: a group heading, a section, or the pinned "Skin" row at the top of the layers.
    final class Item: NSObject {
        /// The section name: the identity for code, selection, errors and pasteboards (never shown as a title).
        let title: String
        let detail: String
        let kind: InspectedSectionKind?
        /// The pinned first row of the layers, which selects the skin itself (nothing selected).
        let isSkin: Bool
        var children: [Item] = []
        /// What the row shows as its title (docs/editor-friendly.md §6, `LayerNaming`).
        var display: String
        /// The row's second line (empty: none).
        var subtitle = ""
        /// The row's SF Symbol (nil: none).
        var symbol: String?
        /// A folded run of repeated layers or data (§5.2 "Groups"): its members' section names, first to last in file
        /// order; nil for a single section.
        var seriesMembers: [String]?
        /// Locked in the editor, so canvas clicks pass through it (§9.6; never written to the file).
        var isLocked = false
        /// Part of the layer is outside the widget and won't show on the desktop (§9.10).
        var isCutOff = false

        init(title: String, detail: String = "", kind: InspectedSectionKind?, isSkin: Bool = false) {
            self.title = title
            self.detail = detail
            self.kind = kind
            self.isSkin = isSkin
            display = title
        }

        var isGroup: Bool { kind == nil && !isSkin }
    }

    /// One option (or variable) of the selected section.
    struct Row: Equatable {
        var key: String
        var raw: String
        var resolved: String
        var source: String
        var sourceTip: String
        var location: IniSourceLocation?
        var style: SourceStyle
    }

    enum SourceStyle { case own, inherited, runtime }

    enum SidebarTab: Int { case library, layers, data }

    /// What the centre shows: the canvas, canvas and code, or the code (Settings ▸ Editor ▸ "Open skins in").
    typealias Mode = EditorPreferences.OpenSkinsIn

    /// The answer when the window closes with code edits that could not be saved.
    enum CloseChoice { case save, discard, cancel }

    /// One option value to write.
    struct Edit: Equatable {
        var section: String
        var key: String
        var value: String
        /// Into the section itself (geometry) rather than where the value is defined.
        var own: Bool
    }

    unowned let app: AppController
    var config: String
    weak var controller: SkinController?
    var selectedSection: String?
    /// Every section of the skin (for lookups); the list shows `listItems` of the current tab.
    var allItems: [Item] = []
    var listItems: [Item] = []
    var sidebarTab = SidebarTab.layers
    lazy var tabControl = NSSegmentedControl()
    /// The layer to go back to from a style opened from its inspector.
    var backSection: String?
    var rows: [Row] = []
    var liveTimer: Timer?
    var canvasTimer: Timer?
    var fileStamps: [String: Date] = [:]
    var keyValueWrites = 0
    /// Until the user zooms, the canvas keeps fitting the skin whenever the canvas or the skin changes size.
    var autoFit = true
    /// Settings ▸ Editor ▸ "Refresh the skin when the file is saved elsewhere" (state.json).
    var liveReload: Bool {
        get { app.state.editor.liveReload }
        set { app.state.updateEditor { $0.liveReload = newValue } }
    }

    // Views (made when the step of the opening that builds them first needs them: `queueOpening`).
    lazy var canvas = SkinCanvasView()
    lazy var canvasScroll = OverlayScrollView()
    lazy var outline = SidebarOutlineView()
    lazy var inspectorScroll = NSScrollView()
    lazy var inspectorStack = EditorStyle.vstack([], spacing: 14)
    lazy var toast = ToastView()
    /// In-window overlays over the panes — chips, badges, tips, status capsules (docs/editor-friendly.md §9, §12) — in
    /// the order they are drawn. `snapshot()` composes them over the panes (NSPopover is never used: it would not show
    /// in an off-screen render).
    var overlayViews: [NSView] = []
    var zoomPill: ZoomPill!
    /// The toolbar's "Backdrop ▾" (the color behind the widget in the editor, never part of it).
    lazy var backdropButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The sticky chip at the top of the canvas when layers are cut off on the desktop (docs/editor-friendly.md §9.10).
    lazy var widgetChip = OverlayCapsule()
    /// What the chip was closed for (it stays closed until the cut-off layers change).
    var dismissedChipSubject: String?
    /// The capsule above the zoom control when the sound data is silent or not heard (§9.9).
    lazy var statusCapsule = OverlayCapsule()
    var silentSince: Date?
    var lastSoundState: SoundState?
    var dismissedSoundState: SoundState?
    /// The clock the overlays measure "silent for 2 seconds" with (self-tests move it).
    var overlayClock: () -> Date = Date.init
    /// The first-run tips (§12), with their arrows.
    lazy var tipViews: [EditorTip: OverlayCapsule] = [.click: OverlayCapsule(arrow: .down), .group: OverlayCapsule(arrow: .up),
                                                 .add: OverlayCapsule(arrow: .none)]
    /// Whether tips show by themselves (nil: only in the running app, which presents windows; self-tests set it).
    var automaticTips: Bool?
    /// T1 was up when Code mode hid the canvas: it comes back with the canvas (unless something was selected).
    var clickTipWaitsForCanvas = false
    /// T1 under the cut-off chip while the chip shows (both sit at the top of the canvas); T2's distance from the top,
    /// set to just under the identity strip's buttons (`positionGroupTip`).
    var clickTipBelowChip: NSLayoutConstraint?
    var clickTipAtTop: NSLayoutConstraint?
    var groupTipTop: NSLayoutConstraint?
    /// The names the chip gave the layers it is about when it appeared: a text's live words would change it every
    /// second (a cut-off clock), re-wrapping the chip each time.
    var chipNames: [String: String] = [:]
    /// The field editing a text layer's words on the canvas (§9.4), and whether its preview hides the layer's words.
    var inlineTextEditor: InlineTextEditor?
    var inlineTextPreview = false

    // Window layout (docs/editor-design.md §1): sidebar | centre | inspector, the centre split canvas | code.
    lazy var mainSplit = NSSplitView()
    lazy var centreSplit = NSSplitView()
    var sidebarPane = NSView()
    var canvasPane = NSView()
    var inspectorPane = NSView()
    lazy var codePane = CodePaneView()
    private var codeViewStorage: CodeEditorView?
    /// The built-in code editor, made when something first needs it — the code pane showing, a self-test (it is put
    /// in the code pane then: `installCodeView`).
    var codeView: CodeEditorView {
        if let view = codeViewStorage { return view }
        let view = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 440, height: 600))
        codeViewStorage = view
        installCodeView(view)
        return view
    }
    /// The code editor if it was made (nil: the code was never shown, so it has nothing to commit or tint).
    var loadedCodeView: CodeEditorView? { codeViewStorage }
    /// The layers / data list (the outline in its scroll view) and the component library: one shows at a time.
    lazy var listPane = NSView()
    /// "+ Add Data Source" above the list on the Data tab.
    lazy var addDataSourceButton = NSPopUpButton(frame: .zero, pullsDown: true)
    var listTop: NSLayoutConstraint?
    private var libraryStorage: ComponentLibraryView?
    /// The Add tab, made when it is first needed (it is put in the sidebar then: `installLibrary`).
    var libraryView: ComponentLibraryView {
        if let view = libraryStorage { return view }
        let view = ComponentLibraryView(onInsert: { [weak self] id in self?.insertComponent(id) })
        libraryStorage = view
        installLibrary(view)
        return view
    }
    /// The Add tab if it was made.
    var loadedLibraryView: ComponentLibraryView? { libraryStorage }
    var canvasMinimum: NSLayoutConstraint?
    var codeMinimum: NSLayoutConstraint?
    /// The inspector's width: the user's (its divider, see `splitView(_:constrainSplitPosition:ofSubviewAt:)`), above
    /// the compression resistance of the cards, so long content is truncated instead of widening the inspector.
    var inspectorWidthConstraint: NSLayoutConstraint?
    var layoutMemory: EditorLayoutMemory
    /// Pane sizes are remembered only once the window has its first layout (the initial one is not the user's).
    var remembersLayout = false
    /// The mode of this window (it survives refreshes and switching to another skin).
    private(set) var mode = Mode.design
    /// Where ⌥⌘↩ goes back to from Design.
    var lastCodeMode = Mode.split
    /// The external app Settings ▸ Editor names (nil: the built-in editor).
    var externalEditor: CodeEditorApp?
    /// "Edit in Built-in Editor" was chosen while an external app is the code editor (this window only).
    var builtInOverride = false
    /// The code pane has not seen the latest refresh (it was hidden).
    var codeStale = true
    /// Selection changes made by the caret in the code pane (they tint the code instead of scrolling it).
    var selectionFromCode = false
    /// The code pane's commit is being written: its refresh must not scroll the code or commit it again.
    var committingCode = false
    /// An inspector rebuild put off while the keyboard focus moved (its `keepScroll`; see `reloadDetail`).
    var deferredInspectorRebuild: Bool?
    var modeGroup: NSToolbarItemGroup?
    lazy var openInControl = NSSegmentedControl()
    /// Asked when the window closes with code edits that could not be saved (self-tests answer it; nil: an alert).
    var closeChoice: (() -> CloseChoice)?
    /// The window's undo stack: pending edits are committed before an undo or redo (see `EditorUndoManager`).
    let editorUndoManager = EditorUndoManager()
    /// Settings ▸ Editor ▸ "Show INI option names" as the inspector was last built with it.
    var shownIniNames = false
    /// What the inspector was last built from (`inspectorInputs`): a refresh that changes none of it keeps the
    /// inspector (no rebuild, only the live values follow).
    var lastInspectorInputs: String?
    /// How many times the inspector was built (self-tests).
    var inspectorRebuildCount = 0
    /// The steps that build the window (see `queueOpening`).
    private(set) var opening: MainThreadSteps?
    /// The window's content while it is being built off the window (`assemblePanes`, `installPanes`).
    private var paneContent: NSView?
    /// Toolbar items not in the toolbar yet (`insertToolbarItems`).
    private var toolbarItemsToInsert: Set<NSToolbarItem.Identifier> = []
    /// Work done in steps once the window is built (`prepareIdleWork`).
    private var idleWork: MainThreadSteps?
    /// Called when the window is ready to be shown (`whenReadyToShow`).
    private var showHandlers: [() -> Void] = []
    private(set) var isReadyToShow = false

    // Live parts of the inspector, refreshed without rebuilding it.
    var headerSubtitle: NSTextField?
    var currentLabels: [String: NSTextField] = [:]
    var liveValueLabel: NSTextField?
    var liveStringLabel: NSTextField?
    var liveRange: NSProgressIndicator?
    var dataLabels: [String: NSTextField] = [:]
    /// Editable fields → what they edit.
    var fieldEdits: [ObjectIdentifier: (key: String, own: Bool, section: String)] = [:]
    var swatchEdits: [ObjectIdentifier: (section: String, key: String, raw: String, variable: String?)] = [:]
    /// Inspector groups the user opened although none of their options is set yet.
    var revealedGroups: Set<String> = []
    var advancedOpen = false
    let inspectorState = InspectorState()
    var addKeyField: NSTextField?
    var addValueField: NSTextField?

    // Gestures, nudges and color picking.
    struct GeometryBase {
        var meter: String
        var raw: (x: String?, y: String?, w: String?, h: String?)
        var frame: SkinRect
        var content: (width: Double, height: Double)
    }
    /// Meters being moved / resized, in skin order (earlier meters first, so relative ones see their final place).
    var geometryBases: [GeometryBase] = []
    var geometryValues: [String: [String: String]] = [:]
    /// Selected meters when more than one is selected on the canvas or in the layer list.
    var selectedMeters: [String] = []
    /// Selection to restore after the next refresh (new layers from insert / duplicate).
    var pendingSelection: [String]?
    var syncingOutline = false
    var gestureName = "Move"
    /// The toast of the gesture being made ("Moved “Audio”"; the undo name is `gestureName`).
    var gestureMessage: String?
    /// Fit Widget to Content on a fixed-size widget: SkinWidth / SkinHeight grow by what the layers move, in the same step.
    var fixedSizeGrowth: [(key: String, size: Double, delta: Double)] = []
    /// Fit Widget to Content: where the widget's window goes with the step being written; its undo moves the window
    /// back only when the files go back (`restore`).
    var widgetMove: WidgetMove?
    typealias WidgetMove = (from: (x: Double, y: Double), to: (x: Double, y: Double))
    var nudgeOffset = (dx: 0.0, dy: 0.0)
    var nudgeTimer: Timer?
    var colorTarget: (section: String, key: String, raw: String, variable: String?)?
    var colorValue: String?
    var colorTimer: Timer?

    static let toolbarSidebar = NSToolbarItem.Identifier("sidebar")
    static let toolbarUndo = NSToolbarItem.Identifier("undo")
    static let toolbarRedo = NSToolbarItem.Identifier("redo")
    static let toolbarLibrary = NSToolbarItem.Identifier("library")
    static let toolbarMode = NSToolbarItem.Identifier("mode")
    static let toolbarBackdrop = NSToolbarItem.Identifier("backdrop")
    static let toolbarLive = NSToolbarItem.Identifier("live")
    static let toolbarCode = NSToolbarItem.Identifier("code")
    static let toolbarMore = NSToolbarItem.Identifier("more")
    static let toolbarInspector = NSToolbarItem.Identifier("inspector")

    /// Minimum and maximum pane sizes (points). The canvas and code minimums are widths with the code on the right and
    /// heights with the code below.
    enum PaneSize {
        static let sidebarMin: CGFloat = 220
        static let sidebarMax: CGFloat = 360
        static let inspectorMin = EditorStyle.inspectorWidth
        static let inspectorMax: CGFloat = 460
        static let canvasMin: CGFloat = 280
        static let codeMin: CGFloat = 300
        static let canvasMinHeight: CGFloat = 200
        static let codeMinHeight: CGFloat = 160
        static let windowMinHeight: CGFloat = 540
    }

    init(app: AppController, controller: SkinController) {
        self.app = app
        self.config = controller.config
        layoutMemory = EditorLayoutMemory(defaults: app.presentsWindows ? UserDefaults.standard : nil)
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        externalEditor = CodeEditorRouter.externalEditor(for: app.state.editor)
        shownIniNames = app.state.editor.showIniNames
        mode = usesExternalEditor ? .design : app.state.editor.openSkinsIn
        if mode != .design { lastCodeMode = mode }
        let opening = MainThreadSteps(name: "Skin editor")
        self.opening = opening
        queueOpening(controller, in: opening)
        if app.opensEditorInSteps { opening.start() } else { opening.finish() }
    }

    /// Builds the window in steps (`MainThreadSteps`), so the skins on the desktop go on animating while it opens (on
    /// macOS 26 a control's first layout takes milliseconds, and the window has hundreds): the panes, made off the
    /// window and put in it laid out; the toolbar, its items a few at a time; the modes and overlays; the widget and the
    /// canvas (`attachParts`) — the window shows then — the layers a few rows at a time, the inspector card by card
    /// (the larger cards row by row), and the rest. After that the Add library and the font menus' faces are made in
    /// steps too (`prepareIdleWork`). Headless (self-tests, snapshots) every step runs before `init` returns, unless
    /// `AppController.opensEditorInSteps` says otherwise.
    private func queueOpening(_ c: SkinController, in steps: MainThreadSteps) {
        func step(_ label: String, _ work: @escaping (InspectorWindowController) -> Void) {
            steps.add(label) { [weak self] in if let self { work(self) } }
        }
        step("sidebar") { $0.buildSidebarPane() }
        step("sidebar layout") { $0.layOutSidebarAhead() }
        step("canvas and inspector") { $0.buildCentrePanes() }
        step("panes") { $0.assemblePanes() }
        step("layout") { $0.installPanes() }
        step("toolbar") { editor in
            editor.buildToolbar(holdingBack: Self.toolbarBatches.flatMap { $0 })
            editor.window?.layoutIfNeeded()
        }
        for batch in Self.toolbarBatches {
            step("toolbar items") { $0.insertToolbarItems(batch) }
        }
        step("modes") { editor in
            editor.applyMode()
            NotificationCenter.default.addObserver(editor, selector: #selector(editor.editorPreferencesChanged),
                                                   name: .desksetEditorPreferencesChanged, object: editor.app.state)
            editor.editorUndoManager.commitPendingEdits = { [weak editor] in editor?.commitPendingEditsBeforeUndo() }
            editor.editorUndoManager.hasPendingEdits = { [weak editor] in editor?.hasPendingVisualEdits ?? false }
            editor.buildCanvasOverlays()
        }
        for part in attachParts(c, opening: steps) {
            steps.add(part.label, part.work)
            if part.label == "canvas" {
                // The app comes to the front a step before its window (each takes a while).
                step("activate") { editor in
                    if editor.app.presentsWindows { editor.app.activateApp(for: editor) }
                }
                step("show") { editor in
                    editor.remembersLayout = true
                    editor.readyToShow()
                }
            }
        }
        step("after opening") { $0.prepareIdleWork() }
    }

    /// Whether the window is still being built.
    var isOpening: Bool { !(opening?.isDone ?? true) }

    /// Once the window is built: the Add tab's library, and the font menus' families, each in its own face (the system
    /// takes a while to make them) — made now, in small steps, so the first Add and the first font menu open at once.
    /// (Not headless: nothing clicks there.)
    private func prepareIdleWork() {
        guard app.opensEditorInSteps else { return }
        let idle = MainThreadSteps(name: "Skin editor (after opening)", budget: 0.004)
        // The Add tab's library, hidden (its thumbnails are drawn one per turn once it is in the window).
        idle.add("library") { [weak self] in _ = self?.libraryView }
        FontFamilies.prepare(in: idle)
        idle.start()
        idleWork = idle
    }

    /// Runs `work` when the window is ready to be shown (now, if it is): its panes laid out, the toolbar, and the
    /// widget on the canvas.
    func whenReadyToShow(_ work: @escaping () -> Void) {
        guard isReadyToShow else { return showHandlers.append(work) }
        work()
    }

    private func readyToShow() {
        isReadyToShow = true
        let handlers = showHandlers
        showHandlers = []
        for work in handlers { work() }
    }

    /// Runs `work` once the window is built (now, if it is).
    func afterOpening(_ work: @escaping () -> Void) {
        guard let opening, !opening.isDone else { return work() }
        opening.whenDone(work)
    }

    /// Builds what is left of the window now: for whatever needs all of it (the skin refreshed or unloaded meanwhile).
    func finishOpening() {
        opening?.finish()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        opening?.cancel()
        idleWork?.cancel()
        liveTimer?.invalidate()
        canvasTimer?.invalidate()
        nudgeTimer?.invalidate()
        colorTimer?.invalidate()
    }

    // MARK: Building

    // The window is built in steps (`queueOpening`): the panes are made off the window (`buildSidebarPane`,
    // `buildCentrePanes`, `assemblePanes`) and go in laid out (`installPanes`); the toolbar follows (`buildToolbar`,
    // `insertToolbarItems`).

    func buildSidebarPane() {
        sidebarPane = buildSidebar()
    }

    /// Lays the sidebar out before it goes in the window, at the size it will have there: its controls' first layout
    /// is most of the window's (the opening does it in a step of its own).
    func layOutSidebarAhead() {
        guard let window else { return }
        let height = window.contentRect(forFrameRect: window.frame).height
        sidebarPane.setFrameSize(NSSize(width: min(max(layoutMemory.sidebarWidth, PaneSize.sidebarMin), PaneSize.sidebarMax),
                                        height: height))
        sidebarPane.layoutSubtreeIfNeeded()
    }

    func buildCentrePanes() {
        canvasPane = buildCanvasArea()
        inspectorPane = buildInspector()
        buildCodePane()
    }

    /// The split views (sidebar | centre | inspector, the centre canvas | code) and the toast, in the view that becomes
    /// the window's content (`installPanes`).
    func assemblePanes() {
        let content = NSView()
        paneContent = content
        centreSplit.isVertical = true
        centreSplit.dividerStyle = .thin
        centreSplit.addArrangedSubview(canvasPane)
        centreSplit.addArrangedSubview(codePane)
        // The canvas takes window resizes; the code keeps its size.
        centreSplit.setHoldingPriority(.init(250), forSubviewAt: 0)
        centreSplit.setHoldingPriority(.init(255), forSubviewAt: 1)

        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.addArrangedSubview(sidebarPane)
        mainSplit.addArrangedSubview(centreSplit)
        mainSplit.addArrangedSubview(inspectorPane)
        sidebarPane.widthAnchor.constraint(greaterThanOrEqualToConstant: PaneSize.sidebarMin).isActive = true
        sidebarPane.widthAnchor.constraint(lessThanOrEqualToConstant: PaneSize.sidebarMax).isActive = true
        inspectorPane.widthAnchor.constraint(greaterThanOrEqualToConstant: PaneSize.inspectorMin).isActive = true
        inspectorPane.widthAnchor.constraint(lessThanOrEqualToConstant: PaneSize.inspectorMax).isActive = true
        // Side panes hold their width when the window resizes. Holding priorities stay below the divider drags (490 /
        // 510), or the user and `setPosition` could not move the dividers. The inspector's width is also held by its
        // own constraint, above the compression resistance of its cards (750) so a long title or formula is truncated
        // instead of widening it; its divider moves that constraint (the split view's delegate).
        mainSplit.setHoldingPriority(.init(260), forSubviewAt: 0)
        mainSplit.setHoldingPriority(.init(250), forSubviewAt: 1)
        mainSplit.setHoldingPriority(.init(261), forSubviewAt: 2)
        let inspectorWidth = inspectorPane.widthAnchor.constraint(
            equalToConstant: clampedInspectorWidth(layoutMemory.inspectorWidth))
        inspectorWidth.priority = .init(752)
        inspectorWidth.isActive = true
        inspectorWidthConstraint = inspectorWidth
        mainSplit.delegate = self
        content.addSubview(mainSplit)
        pin(mainSplit, to: content)
        // The toast floats over the centre, so it shows in every mode (the canvas is hidden in Code).
        content.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: centreSplit.centerXAnchor),
            toast.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 12),
            toast.widthAnchor.constraint(lessThanOrEqualTo: centreSplit.widthAnchor, constant: -24),
        ])
        sidebarPane.isHidden = layoutMemory.sidebarHidden
        inspectorPane.isHidden = layoutMemory.inspectorHidden
        applyOrientation(below: layoutMemory.codeBelow)
    }

    /// The panes go in the window, laid out at the sizes the user left them (or the defaults).
    func installPanes() {
        guard let window, let content = paneContent else { return }
        paneContent = nil
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        applyPaneSizes()
        for split in [mainSplit, centreSplit] {
            NotificationCenter.default.addObserver(self, selector: #selector(splitResized(_:)),
                                                   name: NSSplitView.didResizeSubviewsNotification, object: split)
        }
    }

    /// The toolbar, and the window's frame (the user's, remembered by the running app). `holdingBack` items go in later
    /// (`insertToolbarItems`).
    func buildToolbar(holdingBack: [NSToolbarItem.Identifier] = []) {
        guard let window else { return }
        toolbarItemsToInsert = Set(holdingBack)
        // Toolbars with one identifier are kept alike by AppKit: items put in this one (`insertToolbarItems`) would go
        // into a closed editor's toolbar still around too, where they already are. Nothing else uses the identifier.
        let toolbar = NSToolbar(identifier: "DesksetSkinStudio-\(UUID().uuidString)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.toolbarUndo, Self.toolbarRedo, Self.toolbarLibrary, Self.toolbarMode]
        window.toolbar = toolbar
        // The frame is remembered by the running app only, like the pane sizes: self-tests and snapshots start from the
        // same size every time (and do not overwrite the user's).
        if app.presentsWindows {
            window.setFrameAutosaveName("DesksetSkinEditorWindow")
            if !window.setFrameUsingName("DesksetSkinEditorWindow") { window.center() }
        } else {
            window.center()
        }
    }

    func buildCanvasArea() -> NSView {
        canvasScroll.contentView = CenteringClipView()
        canvasScroll.documentView = canvas
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.autohidesScrollers = true
        canvasScroll.allowsMagnification = true
        canvasScroll.minMagnification = SkinCanvasView.minZoom
        canvasScroll.maxMagnification = SkinCanvasView.maxZoom
        canvasScroll.drawsBackground = false
        canvasScroll.automaticallyAdjustsContentInsets = false
        canvasScroll.translatesAutoresizingMaskIntoConstraints = false
        canvas.skinProvider = { [weak self] in self?.skin }
        canvas.onSelectionChange = { [weak self] names in
            self?.endInlineTextEdit(commit: true)
            self?.canvasSelectionChanged(names)
            self?.updateTips()
        }
        canvas.isLocked = { [weak self] name in self?.isLockedOnCanvas(name) ?? false }
        canvas.layerName = { [weak self] name in self?.displayName(ofSection: name) ?? EditorStyle.displayName(name) }
        canvas.groupName = { [weak self] names in self?.groupDisplayName(names) ?? "\(names.count) layers" }
        canvas.onDoubleClick = { [weak self] name in self?.canvasDoubleClicked(name) }
        canvas.onEnterGroup = { [weak self] _ in self?.dismissTip(.group) }
        canvas.onContextMenu = { [weak self] x, y in self?.canvasMenu(atSkinX: x, y: y) }
        canvas.onChooseData = { [weak self] name, rect in self?.showChooseDataMenu(for: name, at: rect) }
        canvas.onStarter = { [weak self] id in self?.insertComponent(id) }
        canvas.onLayoutChange = { [weak self] in self?.placeInlineTextEditor() }
        canvas.onZoom = { [weak self] z in self?.zoomPill.label.stringValue = "\(Int((z * 100).rounded()))%" }
        canvas.onUserZoom = { [weak self] in self?.autoFit = false }
        canvas.onBeginGesture = { [weak self] names, gesture in self?.beginGeometry(meters: names, gesture: gesture) }
        canvas.onGestureFrames = { [weak self] frames in self?.previewGeometry(frames) }
        canvas.onDelete = { [weak self] in self?.deleteSelection() }
        canvas.onDuplicate = { [weak self] in self?.duplicateSelection() }
        canvas.onEndGesture = { [weak self] keep in
            self?.endGeometry(keep: keep)
            self?.updateWidgetChip()
        }
        canvas.onNudge = { [weak self] dx, dy in self?.nudge(dx: dx, dy: dy) }
        canvas.onDropComponent = { [weak self] id, frame in self?.insertComponent(id, at: frame) }
        canvas.setAccessibilityLabel("Widget canvas")
        NotificationCenter.default.addObserver(self, selector: #selector(canvasMagnified),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: canvasScroll)
        canvasScroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(canvasResized),
                                               name: NSView.frameDidChangeNotification, object: canvasScroll)

        zoomPill = ZoomPill(target: self, zoomOut: #selector(zoomOutClicked), zoomIn: #selector(zoomInClicked),
                            actual: #selector(actualSizeClicked), fit: #selector(fitClicked))
        zoomPill.translatesAutoresizingMaskIntoConstraints = false
        toast.translatesAutoresizingMaskIntoConstraints = false

        let area = NSView()
        area.addSubview(canvasScroll)
        area.addSubview(zoomPill)
        NSLayoutConstraint.activate([
            canvasScroll.topAnchor.constraint(equalTo: area.topAnchor),
            canvasScroll.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            canvasScroll.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            canvasScroll.bottomAnchor.constraint(equalTo: area.bottomAnchor),
            zoomPill.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            zoomPill.bottomAnchor.constraint(equalTo: area.bottomAnchor, constant: -16),
        ])
        return area
    }

    func buildInspector() -> NSView {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        inspectorStack.translatesAutoresizingMaskIntoConstraints = false
        inspectorStack.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 24, right: 16)
        document.addSubview(inspectorStack)
        inspectorScroll.documentView = document
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.drawsBackground = false
        inspectorScroll.automaticallyAdjustsContentInsets = true
        NSLayoutConstraint.activate([
            // Its place as well as its width: nothing else says where it is (ambiguous).
            document.topAnchor.constraint(equalTo: inspectorScroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: inspectorScroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: inspectorScroll.contentView.widthAnchor),
            inspectorStack.topAnchor.constraint(equalTo: document.topAnchor),
            inspectorStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            inspectorStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            inspectorStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let pane = NSVisualEffectView()
        pane.material = .contentBackground
        pane.blendingMode = .withinWindow
        pane.addSubview(inspectorScroll)
        pin(inspectorScroll, to: pane)
        return pane
    }

    func pin(_ view: NSView, to parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    // MARK: Panes

    var isSidebarHidden: Bool { sidebarPane.isHidden }
    var isInspectorHidden: Bool { inspectorPane.isHidden }
    var isCodeVisible: Bool { !codePane.isHidden }
    var isCanvasVisible: Bool { !canvasPane.isHidden }

    /// Shows or hides the sidebar (toolbar button, View ▸ Show/Hide Sidebar ⌃⌘S). A hidden pane keeps its width.
    func setSidebarHidden(_ hidden: Bool) {
        guard sidebarPane.isHidden != hidden else { return }
        if hidden, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: sidebarPane) {
            window?.makeFirstResponder(isCanvasVisible ? canvas : codeView.textView)
        }
        sidebarPane.isHidden = hidden
        layoutMemory.sidebarHidden = hidden
        paneVisibilityChanged()
    }

    /// Shows or hides the inspector (toolbar button, View ▸ Show/Hide Inspector ⌥⌘I).
    func setInspectorHidden(_ hidden: Bool) {
        guard inspectorPane.isHidden != hidden else { return }
        if hidden, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: inspectorPane) {
            window?.makeFirstResponder(isCanvasVisible ? canvas : codeView.textView)
        }
        inspectorPane.isHidden = hidden
        layoutMemory.inspectorHidden = hidden
        paneVisibilityChanged()
    }

    func paneVisibilityChanged() {
        withoutRememberingLayout {
            updateMinimumSize()
            mainSplit.adjustSubviews()
            window?.contentView?.layoutSubtreeIfNeeded()
            placeDividers()
        }
        layoutMemory.save()
        fitIfAutomatic()
    }

    /// Whether the code pane can be shown: the built-in editor is the code editor (or was chosen for this window).
    var usesExternalEditor: Bool { externalEditor != nil && !builtInOverride }

    /// The modes the mode control offers: only Design while an external app edits the code.
    var availableModes: [Mode] { usesExternalEditor ? [.design] : Mode.allCases }

    /// Switches what the centre shows (mode control, View menu ⌃⌘1/2/3, ⌥⌘↩). The code is committed before it is
    /// hidden; a code pane that appears is brought up to date and shows the selection.
    func setMode(_ requested: Mode) {
        let newMode = usesExternalEditor ? .design : requested
        if newMode != .design { lastCodeMode = newMode }
        guard newMode != mode else { return updateModeControl() }
        // Code that could not be saved stays in view.
        if newMode == .design, isCodeVisible, !flushCode() { return updateModeControl() }
        let responder = window?.firstResponder as? NSView
        mode = newMode
        applyMode()
        // The canvas's chip, capsule and tip go with the canvas (they would cover the code).
        updateCanvasOverlays()
        // Keep the keyboard focus in a visible pane.
        if let responder, responder.isHiddenOrHasHiddenAncestor {
            window?.makeFirstResponder(isCanvasVisible ? canvas : codeView.textView)
        }
    }

    func applyMode() {
        let wasCodeVisible = isCodeVisible
        // The code editor is made when the code first shows, in time for this layout.
        if mode != .design { _ = codeView }
        withoutRememberingLayout {
            canvasPane.isHidden = mode == .code
            codePane.isHidden = mode == .design
            updateMinimumSize()
            centreSplit.adjustSubviews()
            window?.contentView?.layoutSubtreeIfNeeded()
            placeDividers()
        }
        updateModeControl()
        if isCodeVisible, !wasCodeVisible || codeStale { syncCodePane(reveal: true) }
        fitIfAutomatic()
    }

    /// ⌥⌘↩: shows the code (the last code mode) or hides it.
    @objc func toggleCodePane(_ sender: Any?) {
        setMode(mode == .design ? lastCodeMode : .design)
    }

    @objc func toggleSidebarPane(_ sender: Any?) { setSidebarHidden(!isSidebarHidden) }
    @objc func toggleInspectorPane(_ sender: Any?) { setInspectorHidden(!isInspectorHidden) }
    @objc func showDesignMode(_ sender: Any?) { setMode(.design) }
    @objc func showSplitMode(_ sender: Any?) { setMode(.split) }
    @objc func showCodeMode(_ sender: Any?) { setMode(.code) }
    @objc func showCodeOnRight(_ sender: Any?) { setCodeBelow(false) }
    @objc func showCodeBelow(_ sender: Any?) { setCodeBelow(true) }

    var codeBelow: Bool { !centreSplit.isVertical }

    /// View ▸ Code on Right / Code Below.
    func setCodeBelow(_ below: Bool) {
        guard below != codeBelow else { return }
        withoutRememberingLayout {
            applyOrientation(below: below)
            updateMinimumSize()
            window?.contentView?.layoutSubtreeIfNeeded()
            placeDividers()
        }
        layoutMemory.codeBelow = below
        layoutMemory.save()
        fitIfAutomatic()
    }

    func applyOrientation(below: Bool) {
        centreSplit.isVertical = !below
        canvasMinimum?.isActive = false
        codeMinimum?.isActive = false
        canvasMinimum = below ? canvasPane.heightAnchor.constraint(greaterThanOrEqualToConstant: PaneSize.canvasMinHeight)
                              : canvasPane.widthAnchor.constraint(greaterThanOrEqualToConstant: PaneSize.canvasMin)
        codeMinimum = below ? codePane.heightAnchor.constraint(greaterThanOrEqualToConstant: PaneSize.codeMinHeight)
                            : codePane.widthAnchor.constraint(greaterThanOrEqualToConstant: PaneSize.codeMin)
        canvasMinimum?.isActive = true
        codeMinimum?.isActive = true
        centreSplit.adjustSubviews()
    }

    /// The smallest content size at which every visible pane keeps its minimum (the inspector: the width the user gave
    /// it, which window resizes do not take away); the window grows when it is smaller (showing the code next to the
    /// canvas needs more room than the canvas alone).
    var minimumContentSize: NSSize {
        let divider = mainSplit.dividerThickness
        var width = centreMinimumWidth
        if !isSidebarHidden { width += PaneSize.sidebarMin + divider }
        if !isInspectorHidden { width += currentInspectorWidth + divider }
        var height = PaneSize.windowMinHeight
        if codeBelow, mode == .split {
            height = max(height, 52 + PaneSize.canvasMinHeight + PaneSize.codeMinHeight + centreSplit.dividerThickness)
        }
        return NSSize(width: ceil(width), height: height)
    }

    /// The narrowest the centre can be in the current mode and orientation.
    var centreMinimumWidth: CGFloat {
        let canvasShown = mode != .code, codeShown = mode != .design
        if codeBelow { return max(canvasShown ? PaneSize.canvasMin : 0, codeShown ? PaneSize.codeMin : 0) }
        return (canvasShown ? PaneSize.canvasMin : 0) + (codeShown ? PaneSize.codeMin : 0)
            + (canvasShown && codeShown ? centreSplit.dividerThickness : 0)
    }

    /// The inspector's width as its constraint holds it (within its minimum and maximum).
    var currentInspectorWidth: CGFloat {
        clampedInspectorWidth(inspectorWidthConstraint?.constant ?? PaneSize.inspectorMin)
    }

    func clampedInspectorWidth(_ width: CGFloat) -> CGFloat {
        min(max(width.isFinite ? width : PaneSize.inspectorMin, PaneSize.inspectorMin), PaneSize.inspectorMax)
    }

    /// The widest the inspector can be without pushing the centre below its minimum (at least its own minimum).
    var inspectorRoom: CGFloat {
        let divider = mainSplit.dividerThickness
        let sidebar = isSidebarHidden ? 0 : sidebarPane.frame.width + divider
        return max(mainSplit.bounds.width - sidebar - centreMinimumWidth - divider, PaneSize.inspectorMin)
    }

    /// The inspector's divider moved (the user dragging it, or `setPosition`): its width constraint follows, within the
    /// inspector's minimum and maximum and the room the centre leaves.
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === mainSplit, dividerIndex == 1, !isInspectorHidden, let constraint = inspectorWidthConstraint
        else { return proposedPosition }
        let total = splitView.bounds.width, divider = splitView.dividerThickness
        let width = min(clampedInspectorWidth(total - proposedPosition - divider), inspectorRoom).rounded()
        constraint.constant = width
        return total - width - divider
    }

    func updateMinimumSize() {
        guard let window else { return }
        let minimum = minimumContentSize
        window.contentMinSize = minimum
        let content = window.contentRect(forFrameRect: window.frame).size
        let dw = max(0, minimum.width - content.width), dh = max(0, minimum.height - content.height)
        guard dw > 0 || dh > 0 else { return }
        var frame = window.frame
        frame.size.width += dw
        frame.size.height += dh
        frame.origin.y -= dh
        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
        }
        window.setFrame(frame, display: window.isVisible)
    }

    /// Puts the dividers where the user left them (or the defaults), for the panes that are visible.
    func applyPaneSizes() {
        withoutRememberingLayout(placeDividers)
    }

    private func placeDividers() {
        if !isSidebarHidden {
            mainSplit.setPosition(min(max(layoutMemory.sidebarWidth, PaneSize.sidebarMin), PaneSize.sidebarMax),
                                  ofDividerAt: 0)
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        if !isInspectorHidden, let constraint = inspectorWidthConstraint {
            let width = min(clampedInspectorWidth(layoutMemory.inspectorWidth), inspectorRoom).rounded()
            if constraint.constant != width {
                constraint.constant = width
                window?.contentView?.layoutSubtreeIfNeeded()
            }
        }
        if isCodeVisible && isCanvasVisible {
            let total = codeBelow ? centreSplit.bounds.height : centreSplit.bounds.width
            let fraction = codeBelow ? layoutMemory.codeFractionBelow : layoutMemory.codeFraction
            let minimum = codeBelow ? PaneSize.codeMinHeight : PaneSize.codeMin
            let canvasMinimum = codeBelow ? PaneSize.canvasMinHeight : PaneSize.canvasMin
            let size = min(max((total * fraction).rounded(), minimum), max(total - canvasMinimum - 1, minimum))
            centreSplit.setPosition(total - size - centreSplit.dividerThickness, ofDividerAt: 0)
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Runs a layout change of the editor's own making, whose pane sizes must not be remembered as the user's.
    func withoutRememberingLayout(_ body: () -> Void) {
        let remembering = remembersLayout
        remembersLayout = false
        body()
        remembersLayout = remembering
    }

    /// A divider moved (by the user, or a window resize): remember the sizes of the visible panes.
    @objc func splitResized(_ notification: Notification) {
        guard remembersLayout else { return }
        if !isSidebarHidden, sidebarPane.frame.width > 0 { layoutMemory.sidebarWidth = sidebarPane.frame.width }
        if !isInspectorHidden, inspectorPane.frame.width > 0, inspectorPane.frame.width != layoutMemory.inspectorWidth {
            layoutMemory.inspectorWidth = inspectorPane.frame.width
            // The window cannot be narrower than the inspector's new width needs (window resizes keep it).
            window?.contentMinSize = minimumContentSize
        }
        if isCodeVisible && isCanvasVisible {
            let total = codeBelow ? centreSplit.bounds.height : centreSplit.bounds.width
            let code = codeBelow ? codePane.frame.height : codePane.frame.width
            if total > 0 {
                let fraction = min(max(code / total, 0.15), 0.85)
                if codeBelow { layoutMemory.codeFractionBelow = fraction } else { layoutMemory.codeFraction = fraction }
            }
        }
        layoutMemory.save()
    }

    // MARK: Toolbar

    var toolbarIdentifiers: [NSToolbarItem.Identifier] {
        [Self.toolbarSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.toolbarUndo, Self.toolbarRedo,
         Self.toolbarLibrary, Self.toolbarMode, .flexibleSpace, Self.toolbarBackdrop, Self.toolbarLive, Self.toolbarCode,
         Self.toolbarMore, Self.toolbarInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIdentifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItemsToInsert.isEmpty ? toolbarIdentifiers : toolbarIdentifiers.filter { !toolbarItemsToInsert.contains($0) }
    }

    /// The toolbar's items are laid out when they first show, each a few milliseconds: while the window is built in
    /// steps, the toolbar starts with its window buttons and the rest go in a batch per step (`insertToolbarItems`),
    /// each where it belongs.
    static let toolbarBatches: [[NSToolbarItem.Identifier]] = [[toolbarUndo, toolbarRedo], [toolbarLibrary, toolbarMode],
                                                              [toolbarBackdrop, toolbarLive], [toolbarCode, toolbarMore]]

    /// Puts a batch of the items held back (`toolbarBatches`) in the toolbar, in their places.
    func insertToolbarItems(_ batch: [NSToolbarItem.Identifier]) {
        guard let toolbar = window?.toolbar else { return }
        let order = toolbarIdentifiers
        for id in batch where toolbarItemsToInsert.contains(id) {
            toolbarItemsToInsert.remove(id)
            guard let target = order.firstIndex(of: id) else { continue }
            // The toolbar holds the items in their order, some missing: the item goes after those that come before it.
            var position = 0, index = 0
            for item in toolbar.items {
                while position < order.count, order[position] != item.itemIdentifier { position += 1 }
                if position >= target { break }
                index += 1
                position += 1
            }
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
        // Laid out now, in this step, not with the next batch or the window's first display.
        window?.layoutIfNeeded()
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: mainSplit, dividerIndex: 0)
        case Self.toolbarMode:
            return makeModeGroup()
        case Self.toolbarLibrary:
            // "+ Add" (docs/editor-friendly.md §4): the Add tab, with the cursor in its search field.
            let item = NSToolbarItem(itemIdentifier: id)
            let button = NSButton(title: "Add", image: EditorStyle.image("plus", size: 12, weight: .semibold) ?? NSImage(),
                                  target: self, action: #selector(showLibrary(_:)))
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageLeading
            button.toolTip = "Add text, graphs, shapes and more to your widget (⇧⌘L)"
            item.view = button
            item.label = "Add"
            item.toolTip = button.toolTip
            return item
        case Self.toolbarBackdrop:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = makeBackdropButton()
            item.label = "Backdrop"
            item.toolTip = Self.backdropTip
            return item
        case Self.toolbarCode:
            return makeCodeItem()
        case Self.toolbarMore:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = EditorStyle.image("ellipsis.circle")
            item.label = "More"
            item.toolTip = "More"
            item.showsIndicator = false
            item.menu = moreMenu()
            return item
        default:
            break
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.isBordered = true
        switch id {
        case Self.toolbarSidebar:
            item.image = EditorStyle.image("sidebar.left")
            item.label = "Sidebar"
            item.toolTip = "Show or hide the sidebar (⌃⌘S)"
            item.action = #selector(toggleSidebarPane(_:))
        case Self.toolbarInspector:
            item.image = EditorStyle.image("sidebar.right")
            item.label = "Inspector"
            item.toolTip = "Show or hide the inspector (⌥⌘I)"
            item.action = #selector(toggleInspectorPane(_:))
        case Self.toolbarUndo, Self.toolbarRedo:
            // ↶ ↷: their tooltips name the step ("Undo Change Bar Color"); disabled with nothing to undo or redo.
            let undo = id == Self.toolbarUndo
            item.image = EditorStyle.image(undo ? "arrow.uturn.backward" : "arrow.uturn.forward")
            item.label = undo ? "Undo" : "Redo"
            item.toolTip = undoToolbarTip(undo: undo)
            item.action = undo ? #selector(undoClicked(_:)) : #selector(redoClicked(_:))
        case Self.toolbarLive:
            item.image = EditorStyle.image(liveReload ? "bolt.fill" : "bolt.slash")
            item.label = "Live Reload"
            item.toolTip = "Reload the widget when its files change on disk"
            item.action = #selector(liveReloadClicked(_:))
        default:
            return nil
        }
        return item
    }

    /// Design | Split | Code (only Design while an external app edits the code).
    func makeModeGroup() -> NSToolbarItemGroup {
        let modes = availableModes
        let group = NSToolbarItemGroup(itemIdentifier: Self.toolbarMode, titles: modes.map(\.title),
                                       selectionMode: .selectOne, labels: modes.map(\.title), target: self,
                                       action: #selector(modeGroupChanged(_:)))
        group.label = "Mode"
        group.controlRepresentation = .expanded
        let keys = ["1", "2", "3"]
        for (i, item) in group.subitems.enumerated() where i < modes.count {
            item.toolTip = "\(modes[i].help) (⌃⌘\(keys[Mode.allCases.firstIndex(of: modes[i]) ?? i]))"
        }
        group.selectedIndex = modes.firstIndex(of: mode) ?? 0
        modeGroup = group
        return group
    }

    @objc func modeGroupChanged(_ sender: Any?) {
        guard let group = (sender as? NSToolbarItemGroup) ?? modeGroup else { return }
        let modes = availableModes
        let index = group.selectedIndex
        guard index >= 0, index < modes.count else { return }
        setMode(modes[index])
    }

    func updateModeControl() {
        modeGroup?.selectedIndex = availableModes.firstIndex(of: mode) ?? 0
    }

    /// "Show in Code" with the built-in editor; "Open in <App>" with a pull-down otherwise.
    func makeCodeItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.toolbarCode)
        guard usesExternalEditor, let editor = externalEditor else {
            item.image = EditorStyle.image("curlybraces")
            item.label = "Show in Code"
            item.toolTip = "Show the selection in the code (⌥⌘↩ shows or hides the code)"
            item.target = self
            item.action = #selector(openInEditor)
            item.isBordered = true
            return item
        }
        let title = Self.openInTitle(editor)
        openInControl.segmentCount = 2
        openInControl.trackingMode = .momentary
        openInControl.segmentStyle = .separated
        openInControl.setImage(editor.icon, forSegment: 0)
        openInControl.setImageScaling(.scaleProportionallyDown, forSegment: 0)
        openInControl.setLabel(title, forSegment: 0)
        openInControl.setToolTip("Open the selection in \(editor.name) (Settings ▸ Editor)", forSegment: 0)
        openInControl.setLabel("", forSegment: 1)
        openInControl.setImage(EditorStyle.image("chevron.down", size: 9, weight: .semibold), forSegment: 1)
        openInControl.setWidth(22, forSegment: 1)
        openInControl.setMenu(openInMenu(editor), forSegment: 1)
        openInControl.setShowsMenuIndicator(false, forSegment: 1)
        openInControl.setToolTip("More ways to edit the code", forSegment: 1)
        openInControl.target = self
        openInControl.action = #selector(openInClicked(_:))
        openInControl.setAccessibilityLabel(title)
        item.view = openInControl
        item.label = title
        item.toolTip = title
        return item
    }

    static func openInTitle(_ editor: CodeEditorApp) -> String { "Open in \(editor.name)" }

    /// The title of the code button ("Show in Code" or "Open in <App>").
    var codeButtonTitle: String {
        guard usesExternalEditor, let editor = externalEditor else { return "Show in Code" }
        return Self.openInTitle(editor)
    }

    func openInMenu(_ editor: CodeEditorApp) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add(Self.openInTitle(editor), #selector(openInEditor))
        menu.addItem(.separator())
        add("Edit in Built-in Editor", #selector(editInBuiltInEditor(_:)))
        add("Reveal in Finder", #selector(revealInFinder(_:)))
        menu.addItem(.separator())
        add("Change Default Editor…", #selector(changeDefaultEditor(_:)))
        return menu
    }

    @objc func openInClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { openInEditor() }
    }

    /// The toolbar's Backdrop tooltip (§4).
    static let backdropTip = "The color behind your widget in the editor. It isn't part of the widget."

    /// "Backdrop ▾": Transparent · Dark · Light, the current one checked.
    func makeBackdropButton() -> NSPopUpButton {
        let button = backdropButton
        button.removeAllItems()
        button.bezelStyle = .texturedRounded
        button.addItem(withTitle: "Backdrop")
        for b in SkinCanvasView.Backdrop.allCases {
            let item = NSMenuItem(title: b.title, action: #selector(backdropChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = b.rawValue
            item.image = EditorStyle.image(b.symbol)
            button.menu?.addItem(item)
        }
        button.item(at: 0)?.image = EditorStyle.image(canvas.backdrop.symbol, size: 12)
        button.toolTip = Self.backdropTip
        button.setAccessibilityLabel("Backdrop")
        updateBackdropButton()
        return button
    }

    func updateBackdropButton() {
        for item in backdropButton.itemArray.dropFirst() { item.state = item.tag == canvas.backdrop.rawValue ? .on : .off }
        backdropButton.item(at: 0)?.image = EditorStyle.image(canvas.backdrop.symbol, size: 12)
    }

    /// Backdrop ▾ and View ▸ Canvas Backdrop ▸.
    @objc func backdropChosen(_ sender: NSMenuItem) {
        canvas.backdrop = SkinCanvasView.Backdrop(rawValue: sender.tag) ?? .checkerboard
        // Remembered for this widget.
        let key = config.lowercased()
        if !key.isEmpty { app.state.updateEditor { $0.backdrops[key] = self.canvas.backdrop.rawValue } }
        updateBackdropButton()
    }

    /// The Backdrop for a widget being opened: the one chosen for it before; else Dark for a see-through widget whose
    /// content is mostly light (white words on the white checkerboard can't be seen, and nothing says why), picked
    /// once and remembered; else the checkerboard.
    func backdrop(for skin: Skin, config: String) -> SkinCanvasView.Backdrop {
        let key = config.lowercased()
        if let stored = app.state.editor.backdrops[key], let backdrop = SkinCanvasView.Backdrop(rawValue: stored) { return backdrop }
        let background = LayerNaming.background(in: skin)
        let panel = LayerThumbnails.ownPanelColor(of: skin, background: background)
        guard (panel?.a ?? 0) < 128, LayerThumbnails.contentIsLight(skin, except: background) else { return .checkerboard }
        app.state.updateEditor { $0.backdrops[key] = SkinCanvasView.Backdrop.dark.rawValue }
        return .dark
    }

    /// The toolbar's ↶ / ↷ tooltip: the step they undo or redo.
    func undoToolbarTip(undo: Bool) -> String {
        guard let manager = window?.undoManager else { return undo ? "Undo" : "Redo" }
        if undo {
            return manager.canUndo && !manager.undoActionName.isEmpty ? "Undo \(manager.undoActionName)" : "Undo"
        }
        return manager.canRedo && !manager.redoActionName.isEmpty ? "Redo \(manager.redoActionName)" : "Redo"
    }

    @objc func undoClicked(_ sender: Any?) { window?.undoManager?.undo() }
    @objc func redoClicked(_ sender: Any?) { window?.undoManager?.redo() }

    func moreMenu() -> NSMenu {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Reload Widget", action: #selector(refreshClicked), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let finder = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
        finder.target = self
        menu.addItem(finder)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Editor Settings…", action: #selector(changeDefaultEditor(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    /// Replaces toolbar items whose look depends on the code-editor setting.
    func reloadToolbarItems(_ ids: [NSToolbarItem.Identifier]) {
        guard let toolbar = window?.toolbar else { return }
        for id in ids {
            guard let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) else { continue }
            toolbar.removeItem(at: index)
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
    }

    // MARK: Code editor setting

    /// Settings ▸ Editor changed: font size, live reload, and whether the code opens here or in another app.
    @objc func editorPreferencesChanged() {
        loadedCodeView?.setFontSize(CGFloat(app.state.editor.codeFontSize))
        if let live = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.toolbarLive }) {
            live.image = EditorStyle.image(liveReload ? "bolt.fill" : "bolt.slash")
        }
        canvas.showsContentOutside = app.state.editor.showsContentOutside
        // "Show INI option names" changes the labels of the open inspector at once.
        if app.state.editor.showIniNames != shownIniNames {
            shownIniNames = app.state.editor.showIniNames
            if controller != nil { window?.subtitle = shownIniNames ? config : "" }
            rebuildKeepingScroll()
        }
        let editor = CodeEditorRouter.externalEditor(for: app.state.editor)
        guard editor != externalEditor else { return }
        externalEditor = editor
        builtInOverride = false
        if usesExternalEditor, mode != .design { setMode(.design) }
        reloadToolbarItems([Self.toolbarMode, Self.toolbarCode])
        updateModeControl()
    }

    /// "Edit in Built-in Editor" (the Open-in pull-down): the code pane for this window, once.
    @objc func editInBuiltInEditor(_ sender: Any?) {
        builtInOverride = true
        reloadToolbarItems([Self.toolbarMode, Self.toolbarCode])
        setMode(.split)
        revealSelectionInCode()
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let file = selectionLocation?.file ?? skin?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    @objc func changeDefaultEditor(_ sender: Any?) {
        SettingsWindowController.show(app: app, pane: .editor)
    }

    // MARK: Menus

    /// ⇧⌘L and the toolbar's "+ Library": the Library tab, with the cursor in its search field.
    @objc func showLibrary(_ sender: Any?) {
        setSidebarHidden(false)
        selectSidebarTab(.library)
        libraryView.focusSearch()
    }

    /// File ▸ Save (⌘S): writes pending nudges, colors and code now.
    @objc func saveSkinCode(_ sender: Any?) {
        commitPendingNudge()
        commitPendingColor()
        if !(loadedCodeView?.commitNow(explicit: true) ?? true) {
            toast.show("Could not save the code", error: true)
            NSSound.beep()
        }
    }

    /// Edit ▸ Find while the focus is elsewhere: the code pane's find bar.
    @objc func performFindPanelAction(_ sender: Any?) {
        guard isCodeVisible else { return NSSound.beep() }
        window?.makeFirstResponder(codeView.textView)
        codeView.textView.performFindPanelAction(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSidebarPane(_:)):
            item.title = isSidebarHidden ? "Show Sidebar" : "Hide Sidebar"
        case #selector(toggleInspectorPane(_:)):
            item.title = isInspectorHidden ? "Show Inspector" : "Hide Inspector"
        case #selector(showDesignMode(_:)):
            item.state = mode == .design ? .on : .off
        case #selector(showSplitMode(_:)):
            item.state = mode == .split ? .on : .off
            return !usesExternalEditor
        case #selector(showCodeMode(_:)):
            item.state = mode == .code ? .on : .off
            return !usesExternalEditor
        case #selector(toggleCodePane(_:)):
            item.title = isCodeVisible ? "Hide Code" : "Show Code"
            return !usesExternalEditor
        case #selector(showCodeOnRight(_:)):
            item.state = codeBelow ? .off : .on
            return !usesExternalEditor
        case #selector(showCodeBelow(_:)):
            item.state = codeBelow ? .on : .off
            return !usesExternalEditor
        case #selector(zoomInClicked), #selector(zoomOutClicked), #selector(actualSizeClicked), #selector(fitClicked):
            return skin != nil && isCanvasVisible
        case #selector(componentChosen(_:)):
            return skin != nil
        case #selector(saveSkinCode(_:)), #selector(refreshClicked), #selector(revealInFinder(_:)):
            return controller != nil
        case #selector(toggleRainmeterDetails(_:)):
            item.state = app.state.editor.showIniNames ? .on : .off
        case #selector(toggleContentOutside(_:)):
            item.state = app.state.editor.showsContentOutside ? .on : .off
        case #selector(backdropChosen(_:)):
            item.state = item.tag == canvas.backdrop.rawValue ? .on : .off
        case #selector(fitWidgetToContentClicked(_:)):
            return cutOffLayers().contains { !$0.edges.intersection([.left, .top]).isEmpty }
        case #selector(performFindPanelAction(_:)):
            return isCodeVisible
        case #selector(editInBuiltInEditor(_:)):
            return usesExternalEditor
        default:
            break
        }
        return true
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.toolbarCode, Self.toolbarLive: return controller != nil
        case Self.toolbarUndo:
            item.toolTip = undoToolbarTip(undo: true)
            return window?.undoManager?.canUndo ?? false
        case Self.toolbarRedo:
            item.toolTip = undoToolbarTip(undo: false)
            return window?.undoManager?.canRedo ?? false
        default: return true
        }
    }

    /// View ▸ Show Rainmeter Details (Settings ▸ Editor): option names, section names and every setting.
    @objc func toggleRainmeterDetails(_ sender: Any?) {
        app.state.updateEditor { $0.showIniNames.toggle() }
    }

    /// View ▸ Show Content Outside the Widget: the ghost around the widget (§9.10).
    @objc func toggleContentOutside(_ sender: Any?) {
        app.state.updateEditor { $0.showsContentOutside.toggle() }
    }

    @objc func fitWidgetToContentClicked(_ sender: Any?) { fitWidgetToContent() }

    /// Esc where no field or the canvas takes it (the layer list, the inspector): up one level, as the breadcrumb's
    /// last part does (docs/editor-friendly.md §7.1) — member → group → widget.
    override func cancelOperation(_ sender: Any?) { selectParentLevel() }

    // MARK: Skin binding

    /// Binds to a (re)loaded skin controller of the edited config: layers and inspector rebuilt, the previous
    /// selection kept when the section still exists, the code pane re-read (clean buffers keep caret and scroll).
    func attach(_ c: SkinController) {
        // Refreshed (or another skin chosen) while the window is still being built: the rest is built first.
        finishOpening()
        for part in attachParts(c) { part.work() }
    }

    /// What binding to a skin controller takes, in order (`attach` runs the parts at once): the widget, the canvas, the
    /// layers, the inspector, the live values and the code. With `opening`, the steps that build the window: the window
    /// shows after the canvas part (`queueOpening`), the layer list's first cells are made ahead, and the inspector is
    /// built card by card.
    func attachParts(_ c: SkinController, opening: MainThreadSteps? = nil) -> [MainThreadSteps.Step] {
        var otherSkin = false, pendingApplied = false
        var previousSelection: String?
        var keep: Item?
        var parts: [MainThreadSteps.Step] = []
        func part(_ label: String, _ work: @escaping (InspectorWindowController) -> Void) {
            parts.append((label, { [weak self] in if let self { work(self) } }))
        }
        part("widget") { editor in
            otherSkin = editor.controller.map { $0.config.lowercased() != c.config.lowercased() } ?? false
            if otherSkin { editor.flushCode() }
            let newWidget = editor.controller?.config.lowercased() != c.config.lowercased()
            previousSelection = editor.selectedSection
            pendingApplied = editor.pendingSelection != nil
            editor.controller = c
            editor.config = c.config
            editor.canvas.isEditable = true
            if newWidget {
                editor.canvas.backdrop = editor.backdrop(for: c.skin, config: c.config)
                editor.updateBackdropButton()
            }
            let name = Self.skinName(c)
            editor.window?.title = name.isEmpty ? c.config : name
            // The widget's name only: "Audio\Visualizer" is an engine path (with Rainmeter Details, it is shown).
            editor.window?.subtitle = editor.app.state.editor.showIniNames ? c.config : ""
            if otherSkin { editor.autoFit = true }
        }
        part("canvas") { editor in
            editor.updateCanvasModel()
            editor.canvas.updateSize()
            editor.canvas.needsDisplay = true
            // The window shows next, with the widget as big as it will be.
            if opening != nil { editor.fitIfAutomatic() }
        }
        if let opening {
            part("layer cells") { $0.prepareListCells(in: opening, skin: c.skin) }
        }
        part("layers") { editor in
            if let opening { editor.loadListRowsInSteps(opening) }
            editor.rebuildSidebar()
            if let pending = editor.pendingSelection {
                editor.pendingSelection = nil
                let names = pending.filter { c.skin.meter(named: $0) != nil || c.skin.measure(named: $0) != nil }
                let meters = names.filter { c.skin.meter(named: $0) != nil }
                editor.selectedMeters = meters.count > 1 ? meters : []
                editor.selectedSection = names.last ?? editor.selectedSection
                if let name = names.last, c.skin.measure(named: name) != nil, editor.sidebarTab == .layers {
                    editor.sidebarTab = .data
                    editor.reloadList()
                }
            }
            editor.selectedMeters = editor.selectedMeters.filter { c.skin.meter(named: $0) != nil }
            if editor.selectedMeters.count < 2 { editor.selectedMeters = [] }
            keep = editor.selectedSection.flatMap { name in
                editor.allItems.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            }
            editor.selectedSection = keep?.title
            editor.syncOutlineSelection()
        }
        part("inspector") { editor in editor.reloadDetail(keepScroll: keep != nil, inSteps: opening) }
        part("live values") { editor in
            editor.fitIfAutomatic()
            editor.refreshInlineTextEditor()
            editor.updateCanvasOverlays()
            editor.fileStamps = editor.stamps(for: c.skin.sourceFiles)
            editor.keyValueWrites = c.skin.keyValueWrites
            editor.startTimers()
        }
        part("code") { editor in
            // The code follows the refresh; it scrolls only to a new layer added from the canvas or another skin.
            let reveal = !editor.committingCode
                && (otherSkin || (pendingApplied && editor.selectedSection != previousSelection))
            editor.syncCodePane(reveal: reveal, otherSkin: otherSkin)
        }
        return parts
    }

    /// The name the window shows: the skin's `[Metadata] Name`, else its folder.
    static func skinName(_ c: SkinController) -> String {
        ManageModel.metadataValue(c.skin.metadata, "Name") ?? String(c.config.split(separator: "\\").last ?? "")
    }

    /// The edited skin was unloaded. What is still pending is written first, while the skin is known: typed code, a
    /// value typed in a field, a preview, a nudge, a color. (Code typed afterwards can still be saved: `perform` writes
    /// without a skin.)
    func detach() {
        finishOpening()
        endInlineTextEdit(commit: true)
        flushCode()
        commitInspectorEditing()
        commitPendingPreview()
        commitPendingNudge()
        commitPendingColor()
        cancelPendingEdits()
        controller = nil
        liveTimer?.invalidate()
        liveTimer = nil
        canvasTimer?.invalidate()
        canvasTimer = nil
        canvas.isEditable = false
        canvas.setSelection(nil)
        canvas.needsDisplay = true
        allItems = []
        listItems = []
        rows = []
        outline.reloadData()
        rebuildInspector()
        loadedCodeView?.tintSection(lines: nil)
    }

    /// Closing with code that could not be saved asks first: Save (try again), Discard Changes, or Cancel. Everything
    /// else still pending is written first: a value typed in an inspector field (closing does not end its editing),
    /// a slider or stepper preview, a nudge, a color. Quitting runs this too (`canTerminate`).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        endInlineTextEdit(commit: true)
        commitInspectorEditing()
        if editedInspectorField != nil { sender.makeFirstResponder(nil) }
        commitPendingPreview()
        commitPendingNudge()
        commitPendingColor()
        guard let codeView = loadedCodeView else { return true }
        if codeView.commitNow(explicit: true) || !codeView.hasUncommittedChanges { return true }
        switch askAboutUncommittedCode() {
        case .save:
            return codeView.commitNow(explicit: true)
        case .discard:
            codeView.discardUncommittedChanges()
            return true
        case .cancel:
            return false
        }
    }

    /// Quitting the app (⌘Q, logging out): the same check as closing the window, which stays open when the answer is
    /// Cancel (or Save fails again).
    func canTerminate() -> Bool {
        guard let window else { return true }
        return windowShouldClose(window)
    }

    func askAboutUncommittedCode() -> CloseChoice {
        if let closeChoice { return closeChoice() }
        // Without windows (self-tests, snapshots) nobody can be asked: keep the edits.
        guard app.presentsWindows, let window else { return .cancel }
        // Quitting while the editor is minimized or behind other windows: show what the question is about.
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        let dirty = codeView.files.filter { codeView.isDirty($0) }.map(\.lastPathComponent)
        let alert = NSAlert()
        alert.messageText = "Your changes to \(dirty.isEmpty ? "the code" : dirty.joined(separator: ", ")) couldn’t be saved"
        alert.informativeText = "Save tries again. If you discard them, the files stay as they are on disk."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    func windowWillClose(_ notification: Notification) {
        opening?.cancel()
        idleWork?.cancel()
        commitPendingNudge()
        commitPendingColor()
        InspectorColorPanel.shared.release(self)
        liveTimer?.invalidate()
        liveTimer = nil
        canvasTimer?.invalidate()
        canvasTimer = nil
        controller = nil
        NotificationCenter.default.removeObserver(self)
        app.inspectorDidClose(self)
    }

    var skin: Skin? { controller?.skin }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { editorUndoManager }

    /// Whether a visual edit waits for its pause (a nudge, a color, a preview).
    var hasPendingVisualEdits: Bool {
        nudgeTimer != nil || colorValue != nil || inspectorState.preview != nil || inspectorState.colorEditValue != nil
    }

    /// Before an undo or redo of the window's stack: edits still waiting for their pause are written, so the undo
    /// takes them back (not the change before them). Not while typing in a field or the code: ⌘Z undoes the typing.
    func commitPendingEditsBeforeUndo() {
        guard !(window?.firstResponder is NSTextView) else { return }
        commitPendingNudge()
        commitPendingColor()
        commitColorEdit()
        commitPendingPreview()
    }


    var selectedMeterName: String? {
        guard let name = selectedSection, skin?.meter(named: name) != nil else { return nil }
        return name
    }

    var selectedKind: InspectedSectionKind? {
        guard let name = selectedSection else { return nil }
        return allItems.first { $0.title == name }?.kind
    }

    // MARK: Detail

    func reloadDetail(keepScroll: Bool = false, inSteps steps: MainThreadSteps? = nil) {
        if isMultiSelection {
            canvas.setSelection(names: selectedMeters)
        } else {
            canvas.setSelection(selectedMeterName, reveal: true)
        }
        rows = currentRows()
        // Nothing the inspector shows changed (a refresh after typing code elsewhere, a write it does not show): the
        // controls stay — no rebuild of the whole column (hundreds of milliseconds), focus, scroll and open menus
        // kept — and only the live values follow.
        if deferredInspectorRebuild == nil, let inputs = inspectorInputs(), inputs == lastInspectorInputs {
            refreshLiveValues()
            return
        }
        // The window being built: card by card (nothing has the focus or was scrolled yet).
        if let steps {
            deferredInspectorRebuild = nil
            return rebuildInspector(in: steps)
        }
        // The keyboard focus is moving: the old first responder is resigning — the code pane committing its typing or
        // an inspector field its value, because the user clicked another control — and that commit refreshed the skin.
        // Rebuilding the inspector now would take the field the user clicked out of the window before it gets the
        // focus, so the inspector is rebuilt when the click is over (and that field gets the focus back).
        if (window as? EditorWindow)?.isChangingFirstResponder == true {
            let scheduled = deferredInspectorRebuild != nil
            deferredInspectorRebuild = (deferredInspectorRebuild ?? true) && keepScroll
            guard !scheduled else { return }
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                guard let self, let keep = self.deferredInspectorRebuild else { return }
                self.rebuildInspectorKeepingFocus(keepScroll: keep)
            }
            return
        }
        rebuildInspectorKeepingFocus(keepScroll: keepScroll)
    }

    /// Where the keyboard focus was in the inspector before it was rebuilt.
    struct InspectorFocus {
        var edit: (key: String, own: Bool, section: String)?
        var identifier: NSUserInterfaceItemIdentifier?
        var text: String
        var selection: NSRange
        /// The field's written value (what its text is compared with): text that differs was typed and not written.
        var original: String?
    }

    /// Rebuilds the inspector for the selection (optionally at the same scroll position). A field that has the
    /// keyboard focus keeps it: the same field of the new inspector (what it edits, else its identifier) takes it
    /// back, with the same text selection when its text did not change.
    func rebuildInspectorKeepingFocus(keepScroll: Bool) {
        deferredInspectorRebuild = nil
        let focus = focusedInspectorField()
        let origin = inspectorScroll.contentView.bounds.origin
        rebuildInspector()
        if keepScroll {
            inspectorScroll.layoutSubtreeIfNeeded()
            inspectorScroll.contentView.scroll(to: origin)
            inspectorScroll.reflectScrolledClipView(inspectorScroll.contentView)
        }
        if let focus { restoreInspectorFocus(focus) }
    }

    func focusedInspectorField() -> InspectorFocus? {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField, field.isDescendant(of: inspectorStack) else { return nil }
        let edit = fieldEdits[ObjectIdentifier(field)]
        let original = (field as? ValueField)?.original ?? (field as? ValueComboBox)?.original
            ?? edit.map { e in (e.own ? rawGeometryValue(e.key) : rows.first { $0.key == e.key }?.raw) ?? "" }
        return InspectorFocus(edit: edit, identifier: field.identifier, text: editor.string, selection: editor.selectedRange(),
                              original: original)
    }

    /// The written value a rebuilt field starts from (see `InspectorFocus.original`).
    func writtenValue(of field: NSTextField) -> String {
        if let value = field as? ValueField { return value.original }
        if let combo = field as? ValueComboBox { return combo.original }
        return field.stringValue
    }

    func restoreInspectorFocus(_ focus: InspectorFocus) {
        guard let window else { return }
        // The field left with the old inspector, which leaves the window itself as the first responder; anything
        // else took the focus on purpose.
        guard window.firstResponder == nil || window.firstResponder === window else { return }
        var fields: [NSTextField] = []
        func collect(_ view: NSView) {
            for v in view.subviews {
                if let field = v as? NSTextField, field.isEditable, field.isEnabled, !field.isHiddenOrHasHiddenAncestor {
                    fields.append(field)
                }
                collect(v)
            }
        }
        collect(inspectorStack)
        var match: NSTextField?
        if let edit = focus.edit {
            match = fields.first { f in
                guard let e = fieldEdits[ObjectIdentifier(f)] else { return false }
                return e.section == edit.section && e.key == edit.key && e.own == edit.own
            }
        }
        if match == nil, let identifier = focus.identifier { match = fields.first { $0.identifier == identifier } }
        guard let field = match, window.makeFirstResponder(field), let editor = field.currentEditor() else { return }
        // Text typed and not written yet (the field was taken out by the rebuild, not left by the user) goes on being
        // edited in the new field — when that field still starts from the same written value.
        if let original = focus.original, focus.text != original, writtenValue(of: field) == original {
            editor.string = focus.text
        }
        let length = (editor.string as NSString).length
        if editor.string == focus.text, focus.selection.location <= length {
            editor.selectedRange = NSRange(location: focus.selection.location,
                                           length: min(focus.selection.length, length - focus.selection.location))
        }
    }

    /// Rows for the selected section, from the live skin.
    func currentRows() -> [Row] {
        guard let name = selectedSection else { return [] }
        return rows(of: name, kind: selectedKind)
    }

    /// Rows (options as written, current values, where defined) of any section.
    func rows(of name: String, kind: InspectedSectionKind?) -> [Row] {
        guard let skin else { return [] }
        if kind == .variables {
            return skin.inspectedVariables().map { v in
                Row(key: v.name, raw: v.raw, resolved: v.current, source: v.location?.description ?? "",
                    sourceTip: v.location.map { "\($0.file.path):\($0.line)" } ?? "", location: v.location, style: .own)
            }
        }
        let sectionFile = skin.sources.location(section: name)?.file
        return skin.inspectedOptions(ofSection: name).map { o in
            var tip: [String] = []
            let source: String
            let style: SourceStyle
            switch o.origin {
            case .own(let l):
                source = l?.description ?? ""
                style = .own
                if let l { tip.append("\(l.file.path):\(l.line)") }
            case .style(let styleName, let l):
                // The line alone when the style is in the same file as the section.
                source = "↳ \(styleName)" + (l.map { $0.file == sectionFile ? "  :\($0.line)" : "  \($0.description)" } ?? "")
                style = .inherited
                tip.append("Inherited from MeterStyle [\(styleName)]")
                if let l { tip.append("\(l.file.path):\(l.line)") }
            case .setOption:
                source = "!SetOption"
                style = .runtime
                tip.append("Changed by an action while the widget runs; not in any file. Editing writes it to the file.")
            }
            if !o.shadowedStyles.isEmpty {
                tip.append("Overrides " + o.shadowedStyles.map { "[\($0)]" }.joined(separator: ", "))
            }
            if !o.variables.isEmpty {
                tip.append("Uses " + o.variables.map { "#\($0)#" }.joined(separator: " "))
            }
            return Row(key: o.key, raw: o.raw, resolved: o.resolved, source: source,
                       sourceTip: tip.joined(separator: "\n"), location: o.origin.location, style: style)
        }
    }

    /// One-line description of a section's live state, in plain words (the header's second line, kept current).
    static func summary(of name: String, kind: InspectedSectionKind?, in skin: Skin) -> String {
        let n = EditorStyle.number
        switch kind {
        case .meter?:
            guard let m = skin.meter(named: name) else { return "" }
            return "\(LayerNaming.kindNoun(m)) · \(n(m.frame.width)) × \(n(m.frame.height))" + (m.hidden ? " · hidden" : "")
        case .measure?:
            guard let m = skin.measure(named: name) else { return "" }
            return LayerNaming.data(m, in: skin).name + (m.disabled ? " · turned off" : "") + (m.paused ? " · paused" : "")
        case .rainmeter?:
            return "\(n(skin.width)) × \(n(skin.height)) px"
        case .variables?:
            return "What the widget's layers share, as written in its files"
        case .metadata?:
            return "Shown in Manage Widgets"
        case .other?, nil:
            let users = styleUsers(name, in: skin)
            return users.isEmpty ? "A look no layer uses" : "A look shared with \(users.count) layer\(users.count == 1 ? "" : "s")"
        }
    }

    static func styleUsers(_ name: String, in skin: Skin) -> [String] {
        skin.meters.filter { m in
            OptionValue.list(m.rawOption("MeterStyle") ?? "").contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }.map(\.name)
    }

    /// Path relative to the Skins folder when inside it.
    static func displayPath(_ url: URL, skin: Skin) -> String {
        let path = url.standardizedFileURL.path
        let root = skin.skinsDirectory.standardizedFileURL.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    // MARK: Buttons

    @objc func zoomInClicked() { autoFit = false; canvas.zoomIn() }
    @objc func zoomOutClicked() { autoFit = false; canvas.zoomOut() }
    @objc func actualSizeClicked() { autoFit = false; canvas.setZoom(1) }
    @objc func fitClicked() { autoFit = true; canvas.zoomToFit() }
    @objc func canvasMagnified() { autoFit = false; canvas.onZoom?(canvas.zoom) }
    @objc func canvasResized() {
        fitIfAutomatic()
        relayoutCanvasOverlays()
    }
    @objc func liveReloadClicked(_ sender: NSToolbarItem) {
        liveReload.toggle()
        sender.image = EditorStyle.image(liveReload ? "bolt.fill" : "bolt.slash")
        toast.show(liveReload ? "Live reload on — saving in another editor reloads the widget" : "Live reload off")
    }

    /// Fits the skin while the user has not chosen a zoom.
    func fitIfAutomatic() {
        guard autoFit, isCanvasVisible, canvasScroll.contentSize.width > 50, canvasScroll.contentSize.height > 50 else { return }
        canvas.zoomToFit()
    }

    @objc func refreshClicked() {
        flushCode()
        refreshSkin()
    }

    /// Reloads the edited skin — also after a refresh that failed to load it (the code may have fixed it since).
    func refreshSkin() {
        guard let c = controller else { return }
        if app.controller(for: c.config) === c {
            app.refresh(c)
        } else if app.controller(for: c.config) == nil, c.isStopped {
            app.activate(config: c.config, file: c.file)
        }
    }

    /// Where the selection is written: its section header (the `[Variables]` block for theme values, `[Rainmeter]`
    /// for the skin itself).
    var selectionLocation: IniSourceLocation? {
        guard let skin else { return nil }
        if selectedKind == .variables { return skin.sources.location(section: "Variables") }
        return skin.sources.location(section: selectedSection ?? "Rainmeter")
    }

    /// The code button ("Show in Code" / "Open in <App>") and the inspector's source links: the selection's code, in
    /// the code pane (switching to Split from Design) or in the app Settings ▸ Editor names.
    @objc func openInEditor() {
        guard let skin else { return }
        let location = selectionLocation
        showCode(file: location?.file ?? skin.fileURL, line: location?.line)
    }

    /// A place in the skin's code: in the code pane (Split from Design) with the built-in editor, else in the app
    /// Settings ▸ Editor names (through `CodeEditorRouter`).
    func showCode(file: URL, line: Int?) {
        if usesExternalEditor { return CodeEditorRouter.open(file: file, line: line, app: app) }
        revealInCode(file: file, line: line)
    }

    // MARK: Live values and file watching

    func startTimers() {
        liveTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t

        // The canvas follows the skin's own update rate (at most 30 frames per second, at least once a second).
        canvasTimer?.invalidate()
        let update = Double(skin?.settings.update ?? 1000) / 1000
        let interval = update > 0 ? min(max(update, 1.0 / 30), 1) : 1
        let ct = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.skin != nil, self.isCanvasVisible else { return }
            let before = self.canvas.frame.size
            self.canvas.updateSize()
            if self.canvas.frame.size != before { self.fitIfAutomatic() }
            self.canvas.needsDisplay = true
        }
        ct.tolerance = interval * 0.1
        RunLoop.main.add(ct, forMode: .common)
        canvasTimer = ct
    }

    /// Live values, and live reload: a file changed on disk by something other than this editor (its own writes
    /// update `fileStamps` as they happen) refreshes the skin; the code pane then re-reads its clean buffers.
    ///
    /// When the skin is not refreshed — it wrote its own files with `!WriteKeyValue` (Rainmeter does not refresh for
    /// that either), or live reload is off — the code pane still re-reads them: a clean buffer holding the old text
    /// would otherwise write it back over the change with the next keystroke's commit.
    func tick() {
        guard let c = controller, !c.isStopped else { return }
        if geometryBases.isEmpty, colorValue == nil, !committingCode {
            let now = stamps(for: c.skin.sourceFiles)
            if now != fileStamps {
                fileStamps = now
                let skinWroteThem = c.skin.keyValueWrites != keyValueWrites
                keyValueWrites = c.skin.keyValueWrites
                if skinWroteThem || !liveReload {
                    codeFilesChangedOnDisk()
                    return refreshLiveValues()
                }
                toast.show("Files changed on disk — reloaded the widget")
                app.refresh(c)
                return
            }
        }
        refreshLiveValues()
        updateCanvasOverlays()
    }

    /// The skin's files changed on disk and the skin is not refreshed: the code pane re-reads them (clean buffers
    /// take the new text keeping caret and scroll; dirty ones ask at their commit), or does so when it is shown.
    func codeFilesChangedOnDisk() {
        guard isCodeVisible, let codeView = loadedCodeView else {
            codeStale = true
            return
        }
        codeView.reloadFromDisk(keepCaret: true)
        tintSelectionInCode()
    }

    /// Updates live values (header, current values, measure values) without rebuilding the inspector. It is rebuilt
    /// only when what the files define changes (an option added or removed, a value inherited or set now): values
    /// the running skin sets (`!SetOption`, often on every update) are updated in place, and nothing is rebuilt while
    /// a menu is open or a control follows the mouse. The sidebar's live values follow too, whatever is selected
    /// (`refreshSidebarValues`).
    func refreshLiveValues() {
        defer { refreshSidebarValues() }
        guard let skin, let name = selectedSection else { return }
        headerSubtitle?.stringValue = Self.summary(of: name, kind: selectedKind, in: skin)
        let fresh = currentRows()
        if Self.structure(of: fresh) != Self.structure(of: rows) {
            guard RunLoop.current.currentMode != .eventTracking else { return }
            rows = fresh
            if !isEditingInInspector && geometryBases.isEmpty && colorValue == nil { rebuildInspector() }
        } else {
            let old = rows
            rows = fresh
            for r in fresh {
                guard let label = currentLabels[r.key.lowercased()] else { continue }
                label.stringValue = "= " + r.resolved
                label.isHidden = r.resolved == r.raw
            }
            for (r, before) in zip(fresh, old) where r.style == .runtime && (r.raw != before.raw || r.resolved != before.resolved) {
                updateRuntimeValue(r, section: name)
            }
        }
        if let m = skin.meter(named: name), geometryBases.isEmpty {
            let raw = m.rawGeometry
            for (key, text, value) in [("X", raw.x, m.frame.x), ("Y", raw.y, m.frame.y),
                                        ("W", raw.w, m.frame.width), ("H", raw.h, m.frame.height)] {
                currentLabels["geometry-\(key)"]?.stringValue = "= \(EditorStyle.number(value))"
                currentLabels["geometry-\(key)"]?.isHidden = OptionValue.number(text ?? "") == value
            }
            for measure in m.measures { dataLabels[measure.name]?.stringValue = liveText(measure) }
        }
        updateLiveCard()
    }

    /// What decides the inspector's layout among the rows: which options there are, where each comes from, and the
    /// values the files hold. A value the running skin sets counts only as "set at run time".
    static func structure(of rows: [Row]) -> [String] {
        rows.map { r in
            "\(r.key.lowercased())\u{1F}\(r.style)" + (r.style == .runtime ? "" : "\u{1F}\(r.raw)")
        }
    }

    /// An option the running skin changed (`!SetOption`): its controls show the new value in place.
    func updateRuntimeValue(_ row: Row, section: String) {
        let id = "\(section)/\(row.key)".lowercased()
        for view in inspectorStack.subviewsMatching({ $0.identifier?.rawValue.lowercased() == id }) {
            guard let field = view as? ValueField, field.currentEditor() == nil else { continue }
            field.stringValue = row.raw
            field.original = field.text
        }
        for case let swatch as SwatchButton in inspectorStack.subviewsMatching({
            $0 is SwatchButton && $0.identifier?.rawValue.caseInsensitiveCompare(row.key) == .orderedSame
        }) {
            swatch.color = OptionValue.color(row.resolved)
        }
    }

    var isEditingInInspector: Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView else { return false }
        return field.isDescendant(of: inspectorStack)
    }

    func stamps(for files: [URL]) -> [String: Date] {
        var result: [String: Date] = [:]
        for url in files {
            let path = url.resolvingSymlinksInPath().path
            result[path] = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                ?? .distantPast
        }
        return result
    }

    // MARK: Canvas (docs/editor-friendly.md §9)

    /// What the canvas needs to know about the skin: its runs of repeated layers, its Background, the View options.
    func updateCanvasModel() {
        guard let skin else { return }
        canvas.groups = LayerSeries.detect(in: skin).filter { $0.kind == .layers }.map(\.members)
        canvas.backgroundName = LayerNaming.background(in: skin)
        canvas.showsContentOutside = app.state.editor.showsContentOutside
    }

    /// Whether canvas clicks pass through a layer (§9.6): locked in the editor, or the widget's Background, which is
    /// locked unless the user unlocked it for this widget.
    func isLockedOnCanvas(_ name: String) -> Bool {
        if isLayerLocked(name) { return true }
        guard let background = canvas.backgroundName, background.caseInsensitiveCompare(name) == .orderedSame else {
            return false
        }
        return !app.state.editor.unlockedBackgrounds.contains(config.lowercased())
    }

    /// A run's name: its row's ("16 bars"), else the number and kind of its layers.
    func groupDisplayName(_ names: [String]) -> String {
        let wanted = Set(names.map { $0.lowercased() })
        if let item = allItems.first(where: { $0.seriesMembers.map { Set($0.map { $0.lowercased() }) } == wanted }) {
            return item.display
        }
        guard let skin else { return "\(names.count) layers" }
        return countedLayers(names, in: skin)
    }

    /// The canvas's right-click menu (§9.7): on a layer, Select ▸ (every layer under the pointer, front first, locked
    /// ones too) and the layer menu (`LayerMenu`) for it — its run while the run is not entered, or the selection it
    /// belongs to; on the empty canvas (or a locked layer), Select ▸, Widget Settings, Fit Widget to Content (when
    /// something is cut off) and Zoom to Fit.
    func canvasMenu(atSkinX x: Double, y: Double) -> NSMenu {
        let under = canvas.layers(atSkinX: x, y)
        let menu: NSMenu
        if let hit = canvas.pickableMeter(atSkinX: x, y)?.name {
            let target = canvas.selectedNames.count > 1 && canvas.selectedNames.contains(hit)
                ? canvas.selectedNames : canvas.clickTarget(hit)
            menu = LayerMenu.make(for: target, in: self)
        } else {
            menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(ClosureMenuItem("Widget Settings", symbol: "gearshape") { [weak self] in
                self?.canvasSelectionChanged([])
            })
            if cutOffLayers().contains(where: { !$0.edges.intersection([.left, .top]).isEmpty }) {
                menu.addItem(ClosureMenuItem("Fit Widget to Content", symbol: "arrow.down.right.and.arrow.up.left") {
                    [weak self] in self?.fitWidgetToContent()
                })
            }
            menu.addItem(ClosureMenuItem("Zoom to Fit", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in
                self?.fitClicked()
            })
        }
        if !under.isEmpty {
            let select = NSMenu()
            for name in under {
                let locked = isLockedOnCanvas(name)
                let title = displayName(ofSection: name) + (locked ? " (locked)" : "")
                let item = ClosureMenuItem(title, symbol: skin?.meter(named: name).map { LayerNaming.symbol(forMeterType: $0.type) }) {
                    [weak self] in self?.canvasSelectionChanged([name])
                }
                item.toolTip = name
                select.addItem(item)
            }
            let holder = NSMenuItem(title: "Select", action: nil, keyEquivalent: "")
            holder.submenu = select
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(holder, at: 0)
        }
        return menu
    }

    /// "Choose what this shows ▾" on a bar, graph or gauge without data (§9.8): its Shows menu, as the inspector has
    /// it — the live data of this widget, and New ▸ to add some and show it in one step.
    func chooseDataMenu(for meter: String) -> NSMenu {
        showsMenu(current: nil, popup: false, choose: { [weak self] name in
            guard let self, let skin = self.skin, let m = skin.measure(named: name) else { return }
            self.commit([Edit(section: meter, key: "MeasureName", value: m.name, own: true)],
                        name: "Show " + Self.titleCase(self.dataName(m, in: skin)))
        }, create: { [weak self] choice in
            self?.createLiveData(choice, for: meter, key: "MeasureName")
        })
    }

    func showChooseDataMenu(for meter: String, at rect: NSRect) {
        if canvas.selectedNames != [meter] { canvasSelectionChanged([meter]) }
        guard app.presentsWindows else { return }
        chooseDataMenu(for: meter).popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: canvas)
    }

    // MARK: Snapshot (UISnapshot)

    /// Composes the editor from its panes (sidebar tab contents, canvas, zoom control, code pane with its jump bar and
    /// ruler, inspector) without the window's toolbar: scroll views on macOS 26 add glass edge effects that need the
    /// window server and would cover everything in an off-screen render.
    func snapshot() -> NSBitmapImageRep? {
        guard let content = window?.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let size = content.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let dark = content.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        func shown(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0 }
        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: content) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            // Stand-ins for the sidebar and inspector materials, and the code pane's background.
            if shown(sidebarPane) {
                (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(red: 0.925, green: 0.922, blue: 0.918, alpha: 1)).setFill()
                rect(sidebarPane).fill()
            }
            if shown(inspectorPane) {
                (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(red: 0.965, green: 0.962, blue: 0.957, alpha: 1)).setFill()
                rect(inspectorPane).fill()
            }
            if shown(codePane) {
                NSColor.textBackgroundColor.setFill()
                rect(codePane).fill()
            }
            // The overlays float over the panes, below the zoom control and the toast.
            let contents: [NSView] = sidebarSnapshotViews() + [canvas, loadedCodeView, inspectorScroll.documentView].compactMap { $0 }
            let parts: [NSView] = contents + overlayViews + [zoomPill, toast].compactMap { $0 }
            for view in parts where shown(view) {
                let visible = view.visibleRect
                guard visible.width > 0, visible.height > 0 else { continue }
                let target = view.convert(visible, to: content)
                guard let part = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width * scale),
                                                  pixelsHigh: Int(target.height * scale), bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                part.size = visible.size
                view.cacheDisplay(in: visible, to: part)
                // Materials need the window server: capsules get a stand-in background.
                if view === zoomPill || view === toast
                    || (view is NSVisualEffectView && overlayViews.contains { $0 === view }) {
                    let pill = NSBezierPath(roundedRect: target, xRadius: target.height / 2, yRadius: target.height / 2)
                    (dark ? NSColor(white: 0.24, alpha: 0.96) : NSColor(white: 1, alpha: 0.96)).setFill()
                    pill.fill()
                    NSColor.separatorColor.setStroke()
                    pill.stroke()
                }
                part.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            // Pane dividers.
            NSColor.separatorColor.setFill()
            let panes = [sidebarPane, centreSplit, inspectorPane].filter(shown)
            for (left, right) in zip(panes, panes.dropFirst()) {
                let r = rect(left), next = rect(right)
                NSRect(x: (r.maxX + next.minX) / 2 - 0.5, y: 0, width: 1, height: size.height).fill()
            }
            if shown(canvasPane), shown(codePane) {
                let code = rect(codePane)
                if codeBelow {
                    NSRect(x: code.minX, y: code.maxY, width: code.width, height: 1).fill()
                } else {
                    NSRect(x: code.minX - 1, y: 0, width: 1, height: size.height).fill()
                }
            }
            drawToolbarStandIn(in: content, scale: scale)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The toolbar in the snapshot: the window's own toolbar needs the window server, so its items are drawn as
    /// stand-ins — the same titles, symbols and enabled states — where the toolbar puts them: the sidebar button,
    /// the title, ↶ ↷ "+ Add" and the mode control in the middle, Backdrop, Live Reload, the code button, ⋯ and the
    /// inspector button at the right.
    func drawToolbarStandIn(in content: NSView, scale: CGFloat) {
        // The content view is not flipped: the toolbar is the strip at the top of its bounds.
        let height = max(content.safeAreaInsets.top, 38)
        let width = content.bounds.width
        let top = content.bounds.height - height
        let appearance = content.effectiveAppearance
        func iconButton(_ symbol: String, enabled: Bool = true) -> NSView {
            let b = NSButton(image: EditorStyle.image(symbol) ?? NSImage(), target: nil, action: nil)
            b.bezelStyle = .texturedRounded
            b.contentTintColor = .secondaryLabelColor
            b.isEnabled = enabled
            b.frame.size = NSSize(width: 32, height: 24)
            return b
        }
        func fitted(_ v: NSControl) -> NSView {
            v.sizeToFit()
            v.frame.size.height = 24
            return v
        }
        let manager = window?.undoManager
        let add = NSButton(title: "Add", image: EditorStyle.image("plus", size: 12, weight: .semibold) ?? NSImage(),
                           target: nil, action: nil)
        add.bezelStyle = .texturedRounded
        add.imagePosition = .imageLeading
        let modes = NSSegmentedControl(labels: availableModes.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        modes.selectedSegment = availableModes.firstIndex(of: mode) ?? 0
        let backdrop = NSPopUpButton(frame: .zero, pullsDown: true)
        backdrop.bezelStyle = .texturedRounded
        backdrop.addItem(withTitle: "Backdrop")
        backdrop.item(at: 0)?.image = EditorStyle.image(canvas.backdrop.symbol, size: 12)
        let middle: [NSView] = [iconButton("arrow.uturn.backward", enabled: manager?.canUndo ?? false),
                                iconButton("arrow.uturn.forward", enabled: manager?.canRedo ?? false),
                                fitted(add), fitted(modes)]
        let right: [NSView] = [fitted(backdrop), iconButton(liveReload ? "bolt.fill" : "bolt.slash"),
                               iconButton("curlybraces"), iconButton("ellipsis.circle"), iconButton("sidebar.right")]
        let gap: CGFloat = 8
        func draw(_ views: [NSView], from start: CGFloat) {
            var x = start
            for v in views {
                v.appearance = appearance
                let r = NSRect(x: x, y: top + (height - v.frame.height) / 2, width: v.frame.width, height: v.frame.height)
                v.frame = NSRect(origin: .zero, size: r.size)
                if let part = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: part)
                    part.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                x += r.width + gap
            }
        }
        func span(_ views: [NSView]) -> CGFloat { views.map(\.frame.width).reduce(0, +) + gap * CGFloat(views.count - 1) }
        let sidebarRight = isSidebarHidden ? CGFloat(0) : sidebarPane.convert(sidebarPane.bounds, to: content).maxX
        draw([iconButton("sidebar.left")], from: max(80, sidebarRight - 44))
        let middleStart = (width - span(middle)) / 2
        let titleStart = max(sidebarRight, 124) + 14
        if middleStart - titleStart > 60 {
            let title = NSAttributedString(string: window?.title ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.labelColor])
            let subtitle = NSAttributedString(string: window?.subtitle ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            let room = middleStart - titleStart - 16
            // Without a subtitle the title sits in the middle, as a window title does.
            let titleY = subtitle.length == 0 ? top + (height - 17) / 2 + 2 : top + height / 2
            title.draw(with: NSRect(x: titleStart, y: titleY, width: room, height: 17),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            subtitle.draw(with: NSRect(x: titleStart, y: top + height / 2 - 15, width: room, height: 15),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        draw(middle, from: middleStart)
        draw(right, from: width - 12 - span(right))
    }

    /// Current toast text (self-tests).
    var toastText: String { toast.text }

    /// The snapshot's canvas and window options (`SnapshotOptions`): `--hover` puts the pointer over a layer (as a
    /// mouse move does), `--drag` begins and previews a drag of a layer (not ended), `--edit-text` edits a text
    /// layer's words on the canvas, `--tip` shows a first-run tip, and `--scroll` scrolls the inspector to a card.
    /// The overlays are shown as they settle (a silent sound shows its capsule).
    func applySnapshotCanvasOptions(_ options: SnapshotOptions) {
        updateCanvasOverlays()
        updateSilentData(settled: true)
        if let hover = options.hover {
            canvas.simulateHover(skin?.meter(named: hover)?.name ?? hover)
        }
        if let drag = options.drag, let m = skin?.meter(named: drag.name) {
            if !canvas.selectedNames.contains(m.name) { canvasSelectionChanged(canvas.clickTarget(m.name)) }
            let start = NSPoint(x: canvas.origin.x + CGFloat(m.frame.x + m.frame.width / 2),
                                y: canvas.origin.y + CGFloat(m.frame.y + m.frame.height / 2))
            canvas.beginGesture(.move, at: start)
            canvas.drag(to: NSPoint(x: start.x + CGFloat(drag.dx), y: start.y + CGFloat(drag.dy)), snapping: false)
        }
        if let name = options.editText { beginInlineTextEdit(skin?.meter(named: name)?.name ?? name) }
        if let number = options.tip, let tip = EditorTip(rawValue: number) {
            if tip == .add, sidebarTab != .library { selectSidebarTab(.library) }
            showTip(tip)
        }
        if let title = options.scroll { scrollInspector(toCard: title) }
    }

    /// Scrolls the inspector to the card whose title is `title` (in any case; `--scroll`).
    @discardableResult
    func scrollInspector(toCard title: String) -> Bool {
        let wanted = title.uppercased()
        // The widget page's cards are identified by their title ("card:UPDATE SPEED").
        guard let card = inspectorStack.findSubview(where: { $0.identifier?.rawValue == "card:\(wanted)" })
                ?? inspectorStack.findSubview(where: { v in
            guard v is EditorCard else { return false }
            return v.findSubview(where: { ($0 as? NSTextField)?.stringValue.uppercased() == wanted }) != nil
        }) ?? inspectorStack.findSubview(where: { ($0 as? NSTextField)?.stringValue.uppercased() == wanted }) else {
            return false
        }
        inspectorStack.layoutSubtreeIfNeeded()
        let r = card.convert(card.bounds, to: inspectorScroll.documentView)
        inspectorScroll.contentView.scroll(to: NSPoint(x: 0, y: max(r.minY - 12, 0)))
        inspectorScroll.reflectScrolledClipView(inspectorScroll.contentView)
        return true
    }
}

/// The skin editor's window. It knows when the keyboard focus is moving, so the editor does not rebuild the inspector
/// in the middle of it (see `InspectorWindowController.reloadDetail`).
final class EditorWindow: NSWindow {
    private var focusChanges = 0

    /// True while `makeFirstResponder(_:)` runs: the old first responder is resigning (the code pane commits its typing
    /// then, which refreshes the skin) and the new one has not taken the focus yet.
    var isChangingFirstResponder: Bool { focusChanges > 0 }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        focusChanges += 1
        defer { focusChanges -= 1 }
        return super.makeFirstResponder(responder)
    }
}

/// The code pane's container: the code editor below the toolbar, on the text background (so the strip under the
/// transparent toolbar reads as part of the pane).
final class CodePaneView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// Pane sizes and visibility of the skin editor window, remembered in the user defaults by the running app (self-tests
/// and snapshots pass no defaults and always start from these values).
struct EditorLayoutMemory {
    var sidebarWidth: CGFloat = 262
    var inspectorWidth: CGFloat = InspectorWindowController.PaneSize.inspectorMin
    /// The code's share of the centre, with the code on the right and below.
    var codeFraction: CGFloat = 0.5
    var codeFractionBelow: CGFloat = 0.45
    var sidebarHidden = false
    var inspectorHidden = false
    var codeBelow = false
    let defaults: KeyValueStore?

    static let key = "DesksetSkinEditorLayout"

    init(defaults: KeyValueStore?) {
        self.defaults = defaults
        guard let stored = defaults?.object(forKey: Self.key) as? [String: Any] else { return }
        func number(_ key: String) -> CGFloat? {
            (stored[key] as? NSNumber).map { CGFloat($0.doubleValue) }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        sidebarWidth = number("sidebarWidth") ?? sidebarWidth
        inspectorWidth = number("inspectorWidth") ?? inspectorWidth
        codeFraction = number("codeFraction").map { min(max($0, 0.15), 0.85) } ?? codeFraction
        codeFractionBelow = number("codeFractionBelow").map { min(max($0, 0.15), 0.85) } ?? codeFractionBelow
        sidebarHidden = stored["sidebarHidden"] as? Bool ?? false
        inspectorHidden = stored["inspectorHidden"] as? Bool ?? false
        codeBelow = stored["codeBelow"] as? Bool ?? false
    }

    func save() {
        defaults?.set([
            "sidebarWidth": Double(sidebarWidth), "inspectorWidth": Double(inspectorWidth),
            "codeFraction": Double(codeFraction), "codeFractionBelow": Double(codeFractionBelow),
            "sidebarHidden": sidebarHidden, "inspectorHidden": inspectorHidden, "codeBelow": codeBelow,
        ] as [String: Any], forKey: Self.key)
    }
}

extension NSView {
    /// The first descendant matching `predicate` (depth first).
    func findSubview(where predicate: (NSView) -> Bool) -> NSView? {
        for v in subviews {
            if predicate(v) { return v }
            if let found = v.findSubview(where: predicate) { return found }
        }
        return nil
    }
}
