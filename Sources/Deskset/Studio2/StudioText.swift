import AppKit

/// Every word the Studio window shows, in one English table: the window, its toolbar, panes and popovers read their
/// strings here (`StudioText[.undo]`).
enum StudioText {
    enum Key: String, CaseIterable {
        // The toolbar.
        case undo = "toolbar.undo"
        case undoNamed = "toolbar.undo.named"
        case redo = "toolbar.redo"
        case redoNamed = "toolbar.redo.named"
        case undoRedo = "toolbar.undoRedo"
        case done = "toolbar.done"
        case doneTip = "toolbar.done.tip"
        case widgetName = "toolbar.name"
        case widgetNameTip = "toolbar.name.tip"
        // The copy sentence under the widget's name.
        case copyBuiltIn = "copy.builtIn"
        case copyMadeByYou = "copy.madeByYou"
        case copyRainmeter = "copy.rainmeter"
        case copyNotLoaded = "copy.notLoaded"
        // The popover the name opens.
        case runningTitle = "running.title"
        case runningNothing = "running.nothing"
        case runningBuiltIn = "running.builtIn"
        case runningRainmeter = "running.rainmeter"
        case runningMadeByYou = "running.madeByYou"
        case showInFinder = "running.showInFinder"
        // The panes and window.
        case studioWindow = "window.studio"
        case canvas = "canvas"
        case backdrop = "canvas.backdrop"
        // The canvas: backdrop, preview bar, zoom capsule, caption, capsules.
        case backdropDesktop = "backdrop.desktop"
        case backdropWorkbench = "backdrop.workbench"
        case backdropTransparent = "backdrop.transparent"
        case backdropSolid = "backdrop.solid"
        case backdropSimilar = "backdrop.similar"
        case backdropClose = "backdrop.close"
        case backdropSimilarTip = "backdrop.similar.tip"
        case backdropCloseTip = "backdrop.close.tip"
        case showOtherWidgets = "backdrop.neighbours"
        case previewBar = "preview.bar"
        case previewPrefix = "preview.prefix"
        case previewTip = "preview.tip"
        case lightMode = "preview.light"
        case darkMode = "preview.dark"
        case live = "preview.live"
        case dataTip = "preview.data.tip"
        case interact = "preview.interact"
        case interactTip = "preview.interact.tip"
        case backToLive = "preview.backToLive"
        case previewOnly = "preview.popover.title"
        case macAppearance = "preview.popover.appearance"
        case followMac = "preview.popover.followMac"
        case appearanceLight = "preview.popover.light"
        case appearanceDark = "preview.popover.dark"
        case glass = "preview.popover.glass"
        case glassDefault = "preview.popover.glass.default"
        case glassClear = "preview.popover.glass.clear"
        case glassTinted = "preview.popover.glass.tinted"
        case language = "preview.popover.language"
        case previewFooter = "preview.popover.footer"
        case dataHeader = "data.header"
        case dataPaused = "data.paused"
        case dataLongText = "data.longText"
        case dataNone = "data.none"
        case timeHeader = "data.time"
        case timeFrozen = "data.time.frozen"
        case timePick = "data.time.pick"
        case timePickTitle = "data.time.pick.title"
        case timePickUse = "data.time.pick.use"
        case previewing = "capsule.previewing"
        case previewingData = "capsule.previewing.data"
        case previewingPaused = "capsule.previewing.paused"
        case previewingLongText = "capsule.previewing.longText"
        case previewingNoData = "capsule.previewing.noData"
        case previewingTime = "capsule.previewing.time"
        case wouldOpen = "capsule.wouldOpen"
        case wouldOpenWidget = "capsule.wouldOpenWidget"
        case wouldCloseWidget = "capsule.wouldCloseWidget"
        case wouldSaveSetting = "capsule.wouldSaveSetting"
        case wouldChangeWindow = "capsule.wouldChangeWindow"
        case wouldRunCommand = "capsule.wouldRunCommand"
        case wouldUseDeskset = "capsule.wouldUseDeskset"
        case wouldActOutside = "capsule.wouldActOutside"
        case wouldChange = "capsule.wouldChange"
        case open = "capsule.open"
        case run = "capsule.run"
        case zoomCapsule = "zoom"
        case zoomIn = "zoom.in"
        case zoomOut = "zoom.out"
        case zoomToFit = "zoom.fit"
        case actualSize = "zoom.actualSize"
        case actualSizeShort = "zoom.actualSize.short"
        case captionOnDesktop = "caption.onDesktop"
        case captionNotOnDesktop = "caption.notOnDesktop"
        case captionActualSize = "caption.actualSize"
        case sizeSmall = "size.small"
        case sizeMedium = "size.medium"
        case sizeLarge = "size.large"
        // Announcements.
        case announceOpen = "ax.open"
        case announceUndo = "ax.undo"
        case announceRedo = "ax.redo"
        case announceDone = "announce.done"
        // The code pane, its diagnostics, the log and the menus.
        case codePane = "code.pane"
        case codeFileTip = "code.file.tip"
        case codeOpenIn = "code.openIn"
        case codeLog = "code.log"
        case codeLogTip = "code.log.tip"
        case codeMore = "code.more"
        case codeProblems = "code.problems"
        case codeProblemsMany = "code.problems.many"
        case codeWarnings = "code.warnings"
        case codeWarningsMany = "code.warnings.many"
        case codeProblemsTip = "code.problems.tip"
        case codeWarningsTip = "code.warnings.tip"
        case statusSaved = "code.status.saved"
        case statusHeld = "code.status.held"
        case statusNotSaved = "code.status.notSaved"
        case statusEditing = "code.status.editing"
        case statusLine = "code.status.line"
        case fix = "code.fix"
        case stepTyping = "step.typing"
        case stepFix = "step.fix"
        case diagUnknownMeterKey = "diag.unknownKey.meter"
        case diagUnknownMeasureKey = "diag.unknownKey.measure"
        case diagMeanwhileColorMany = "diag.meanwhile.color.many"
        case diagMeanwhileColorOne = "diag.meanwhile.color.one"
        case diagMeanwhileDefault = "diag.meanwhile.default"
        case diagBadColor = "diag.badColor"
        case diagBadFormula = "diag.badFormula"
        case diagMissingNumber = "diag.formula.missingNumber"
        case diagMissingParen = "diag.formula.missingParen"
        case diagUnknownFunction = "diag.formula.unknownFunction"
        case diagEmptyFormula = "diag.formula.empty"
        case diagCantDrawMany = "diag.cantDraw.many"
        case diagCantDrawOne = "diag.cantDraw.one"
        case diagMissingMeasure = "diag.missingMeasure"
        case diagMissingStyle = "diag.missingStyle"
        case diagMissingInclude = "diag.missingInclude"
        case diagMissingImage = "diag.missingImage"
        case diagUnknownBang = "diag.unknownBang"
        case diagUnknownBangNoGuess = "diag.unknownBang.noGuess"
        case diagBlack = "diag.black"
        case diagWhite = "diag.white"
        case diagColor = "diag.color"
        case nounBar = "noun.bar"
        case nounBars = "noun.bars"
        case nounText = "noun.text"
        case nounTexts = "noun.texts"
        case nounNumber = "noun.number"
        case nounNumbers = "noun.numbers"
        case nounPicture = "noun.picture"
        case nounPictures = "noun.pictures"
        case nounGraph = "noun.graph"
        case nounGraphs = "noun.graphs"
        case nounRing = "noun.ring"
        case nounRings = "noun.rings"
        case nounHand = "noun.hand"
        case nounHands = "noun.hands"
        case nounButton = "noun.button"
        case nounButtons = "noun.buttons"
        case nounShape = "noun.shape"
        case nounShapes = "noun.shapes"
        case nounPart = "noun.part"
        case nounParts = "noun.parts"
        case capsuleCantDraw = "capsule.cantDraw"
        case capsuleCantDrawNamed = "capsule.cantDraw.named"
        case capsuleKeeps = "capsule.keeps"
        case capsuleProblems = "capsule.problems"
        case capsuleProblemsMany = "capsule.problems.many"
        case logTitle = "log.title"
        case logTitleWidget = "log.title.widget"
        case logThisWidget = "log.thisWidget"
        case logAllWidgets = "log.allWidgets"
        case logAllLevels = "log.level.all"
        case logErrors = "log.level.errors"
        case logWarnings = "log.level.warnings"
        case logInfo = "log.level.info"
        case logEmpty = "log.empty"
        case logShowLine = "log.showLine"
        case logStudio = "log.studio"
        case logDesktop = "log.desktop"
        case menuFile = "menu.file"
        case menuEdit = "menu.edit"
        case menuView = "menu.view"
        case menuWidget = "menu.widget"
        case menuWindow = "menu.window"
        case menuHelp = "menu.help"
        case menuClose = "menu.close"
        case menuSave = "menu.save"
        case menuUndo = "menu.undo"
        case menuRedo = "menu.redo"
        case menuCut = "menu.cut"
        case menuCopy = "menu.copy"
        case menuPaste = "menu.paste"
        case menuSelectAll = "menu.selectAll"
        case menuFind = "menu.find"
        case menuFindChange = "menu.find.change"
        case menuFindNext = "menu.find.next"
        case menuFindPrevious = "menu.find.previous"
        case codeNotSavedTitle = "code.notSaved.title"
        case codeNotSavedTheCode = "code.notSaved.theCode"
        case codeNotSavedInfo = "code.notSaved.info"
        case codeNotSavedSave = "code.notSaved.save"
        case codeNotSavedCancel = "code.notSaved.cancel"
        case codeNotSavedDiscard = "code.notSaved.discard"
        case menuCodeAlongside = "menu.view.codeAlongside"
        case menuCodeOnly = "menu.view.codeOnly"
        case menuFullScreen = "menu.view.fullScreen"
        case menuRefresh = "menu.widget.refresh"
        case menuPreviewOptions = "menu.widget.previewOptions"
        case menuMinimize = "menu.window.minimize"
        case menuZoomWindow = "menu.window.zoom"
        case menuLog = "menu.window.log"
        case menuAbout = "menu.app.about"
        case menuSettings = "menu.app.settings"
        case appMenuHide = "menu.app.hide"
        case menuQuit = "menu.app.quit"
    }

    static let table: [Key: String] = [
        .undo: "Undo",
        .undoNamed: "Undo %@",
        .redo: "Redo",
        .redoNamed: "Redo %@",
        .undoRedo: "Undo",
        .done: "Done",
        .doneTip: "Every change is already saved. Closes the Studio.",
        .widgetName: "Widget",
        .widgetNameTip: "Which file runs on your desktop",
        .copyBuiltIn: "Built-in widget · on your desktop",
        .copyMadeByYou: "Made by you · on your desktop",
        .copyRainmeter: "Rainmeter skin · compatibility mode",
        .copyNotLoaded: "Not on your desktop right now",
        .runningTitle: "Running on your desktop",
        .runningNothing: "Nothing: the widget is not on your desktop right now.",
        .runningBuiltIn: "A widget that comes with Deskset.",
        .runningRainmeter: "The skin’s own file: changes are written into it.",
        .runningMadeByYou: "Your widget’s own file: changes are written into it.",
        .showInFinder: "Show in Finder",
        .studioWindow: "Studio",
        .canvas: "Widget canvas",
        .backdrop: "Backdrop",
        .backdropDesktop: "Your Desktop",
        .backdropWorkbench: "Workbench",
        .backdropTransparent: "Transparent",
        .backdropSolid: "Solid",
        .backdropSimilar: "Similar",
        .backdropClose: "Close to your wallpaper",
        .backdropSimilarTip: "macOS does not say which picture shows now; this is one of them.",
        .backdropCloseTip: "Your wallpaper is in a place macOS asks about before it can be read, so a sample close to it stands in.",
        .showOtherWidgets: "Show Other Widgets",
        .previewBar: "Preview",
        .previewPrefix: "Preview:",
        .previewTip: "How the widget looks in this window only",
        .lightMode: "Light Mode",
        .darkMode: "Dark Mode",
        .live: "Live",
        .dataTip: "Sample data and time, in this window only",
        .interact: "Interact",
        .interactTip: "Hover and click in the widget without leaving the Studio; clicks work as they do on the desktop",
        .backToLive: "Back to Live",
        .previewOnly: "Preview only",
        .macAppearance: "Mac appearance",
        .followMac: "Follow Mac",
        .appearanceLight: "Light",
        .appearanceDark: "Dark",
        .glass: "Glass",
        .glassDefault: "Default",
        .glassClear: "Clear",
        .glassTinted: "Tinted (Mac setting)",
        .language: "Language",
        .previewFooter: "Preview only — your widget doesn’t change.",
        .dataHeader: "Data",
        .dataPaused: "Paused",
        .dataLongText: "Long Text",
        .dataNone: "No Data",
        .timeHeader: "Time",
        .timeFrozen: "Frozen at %@",
        .timePick: "Pick a Time…",
        .timePickTitle: "Show the widget at",
        .timePickUse: "Use This Time",
        .previewing: "Previewing %@ · your desktop doesn’t change",
        .previewingData: "sample data %@",
        .previewingPaused: "paused data",
        .previewingLongText: "long text",
        .previewingNoData: "no data",
        .previewingTime: "the time %@",
        .wouldOpen: "Would open %@",
        .wouldOpenWidget: "Would open another widget",
        .wouldCloseWidget: "Would close a widget",
        .wouldSaveSetting: "Would save a setting to its file",
        .wouldChangeWindow: "Would change the widget’s window on the desktop",
        .wouldRunCommand: "Would run a command",
        .wouldUseDeskset: "Would ask Deskset to do something",
        .wouldActOutside: "Would act outside the widget",
        .wouldChange: "Would change %@",
        .open: "Open",
        .run: "Run",
        .zoomCapsule: "Zoom",
        .zoomIn: "Zoom In",
        .zoomOut: "Zoom Out",
        .zoomToFit: "Zoom to Fit",
        .actualSize: "Actual Size",
        .actualSizeShort: "1:1",
        .captionOnDesktop: "Preview %@ · %@ on your desktop",
        .captionNotOnDesktop: "Preview %@ · %@ · not on your desktop yet",
        .captionActualSize: "Actual size · where it is on your desktop",
        .sizeSmall: "Small",
        .sizeMedium: "Medium",
        .sizeLarge: "Large",
        .announceOpen: "Editing “%@”.",
        .announceUndo: "Undid %@",
        .announceRedo: "Redid %@",
        .announceDone: "Saved. Closing the Studio.",
        .codePane: "Code",
        .codeFileTip: "The widget’s files: the main one and every file it includes",
        .codeOpenIn: "Open in %@",
        .codeLog: "Log %d",
        .codeLogTip: "What the widget logged (Window ▸ Log)",
        .codeMore: "More",
        .codeProblems: "%d problem",
        .codeProblemsMany: "%d problems",
        .codeWarnings: "%d warning",
        .codeWarningsMany: "%d warnings",
        .codeProblemsTip: "Can’t draw: the next one",
        .codeWarningsTip: "Still draws, with a default: the next one",
        .statusSaved: "Saved · your desktop is updated",
        .statusHeld: "Saved · your desktop keeps the last working version until the red problem is fixed",
        .statusNotSaved: "Not saved: %@",
        .statusEditing: "Editing · saved when you pause",
        .statusLine: "Line %d",
        .fix: "Fix",
        .stepTyping: "Typing",
        .stepFix: "Fix %@",
        .diagUnknownMeterKey: "%@ isn’t an option of a %@ meter. Did you mean %@?",
        .diagUnknownMeasureKey: "%@ isn’t an option of a %@ measure. Did you mean %@?",
        .diagMeanwhileColorMany: "The %@ draw in the default %@ until then.",
        .diagMeanwhileColorOne: "The %@ draws in the default %@ until then.",
        .diagMeanwhileDefault: "Until then the default %@ applies.",
        .diagBadColor: "%@ isn’t a color: write R,G,B or RRGGBB.",
        .diagBadFormula: "%@ can’t be worked out: %@.",
        .diagMissingNumber: "a number is missing after “%@”",
        .diagMissingParen: "a “)” is missing",
        .diagUnknownFunction: "there’s no function %@",
        .diagEmptyFormula: "there’s nothing in it",
        .diagCantDrawMany: "The %d %@ don’t draw.",
        .diagCantDrawOne: "The %@ doesn’t draw.",
        .diagMissingMeasure: "There’s no measure called %@.",
        .diagMissingStyle: "There’s no section called %@ to use as a style.",
        .diagMissingInclude: "%@ isn’t there, so nothing in it is read.",
        .diagMissingImage: "There’s no picture at %@.",
        .diagUnknownBang: "%@ isn’t a bang. Did you mean %@?",
        .diagUnknownBangNoGuess: "%@ isn’t a bang Rainmeter knows.",
        .diagBlack: "black",
        .diagWhite: "white",
        .diagColor: "color",
        .nounBar: "bar",
        .nounBars: "bars",
        .nounText: "text",
        .nounTexts: "texts",
        .nounNumber: "number",
        .nounNumbers: "numbers",
        .nounPicture: "picture",
        .nounPictures: "pictures",
        .nounGraph: "graph",
        .nounGraphs: "graphs",
        .nounRing: "ring",
        .nounRings: "rings",
        .nounHand: "hand",
        .nounHands: "hands",
        .nounButton: "button",
        .nounButtons: "buttons",
        .nounShape: "shape",
        .nounShapes: "shapes",
        .nounPart: "part",
        .nounParts: "parts",
        .capsuleCantDraw: "The %@ can’t draw",
        .capsuleCantDrawNamed: "%@ can’t draw",
        .capsuleKeeps: "your desktop keeps the last working version",
        .capsuleProblems: "%d problem · the rest still draws",
        .capsuleProblemsMany: "%d problems · the rest still draws",
        .logTitle: "Log",
        .logTitleWidget: "Log · %@",
        .logThisWidget: "This Widget",
        .logAllWidgets: "All Widgets",
        .logAllLevels: "All",
        .logErrors: "Errors",
        .logWarnings: "Warnings",
        .logInfo: "Information",
        .logEmpty: "Nothing logged",
        .logShowLine: "Show the Line",
        .logStudio: "In the Studio",
        .logDesktop: "On the desktop",
        .menuFile: "File",
        .menuEdit: "Edit",
        .menuView: "View",
        .menuWidget: "Widget",
        .menuWindow: "Window",
        .menuHelp: "Help",
        .menuClose: "Close",
        .menuSave: "Save",
        .menuUndo: "Undo",
        .menuRedo: "Redo",
        .menuCut: "Cut",
        .menuCopy: "Copy",
        .menuPaste: "Paste",
        .menuSelectAll: "Select All",
        .menuFind: "Find",
        .menuFindChange: "Find…",
        .menuFindNext: "Find Next",
        .menuFindPrevious: "Find Previous",
        .codeNotSavedTitle: "Your changes to %@ couldn’t be saved",
        .codeNotSavedTheCode: "the code",
        .codeNotSavedInfo: "Save tries again. If you discard them, the files stay as they are on disk.",
        .codeNotSavedSave: "Save",
        .codeNotSavedCancel: "Cancel",
        .codeNotSavedDiscard: "Discard Changes",
        .menuCodeAlongside: "Code Alongside",
        .menuCodeOnly: "Code Only",
        .menuFullScreen: "Enter Full Screen",
        .menuRefresh: "Refresh",
        .menuPreviewOptions: "Preview Options…",
        .menuMinimize: "Minimize",
        .menuZoomWindow: "Zoom",
        .menuLog: "Log",
        .menuAbout: "About Deskset",
        .menuSettings: "Settings…",
        .appMenuHide: "Hide Deskset",
        .menuQuit: "Quit Deskset",
    ]

    static subscript(_ key: Key) -> String { table[key] ?? key.rawValue }

    static func format(_ key: Key, _ arguments: CVarArg...) -> String {
        String(format: self[key], arguments: arguments)
    }

    /// A size in bytes, as the Mac writes it ("20.4 GB"; nothing is "Zero KB": "0 KB").
    static func bytes(_ value: Double, style: ByteCountFormatter.CountStyle) -> String {
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(max(value.isFinite ? value : 0, 0)))
    }

    /// A time since something, in days and hours ("14 d 5 h"), hours and minutes, or minutes.
    static func duration(seconds v: Double) -> String {
        let s = Int(max(v.isFinite ? v : 0, 0))
        let days = s / 86_400, hours = s % 86_400 / 3600, minutes = s % 3600 / 60
        return days > 0 ? "\(days) d \(hours) h" : hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }
}
