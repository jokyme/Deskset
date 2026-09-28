import AppKit

/// The languages the Studio speaks.
enum StudioLanguage: String, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"

    /// `--language en|zh|zh-Hans` (case does not matter).
    init?(argument: String) {
        switch argument.lowercased() {
        case "en", "english": self = .english
        case "zh", "zh-hans", "zh_hans", "chinese": self = .chinese
        default: return nil
        }
    }
}

/// Every word the new Studio window shows, in English and Simplified Chinese, in one table: the window, its toolbar,
/// panes and popovers read their strings here (`StudioText[.undo]`), so they can move to String Catalogs later without
/// hunting through the views. Chinese follows Apple's own words and the full-width punctuation rules (a space between
/// Chinese and Latin letters or digits).
///
/// The language is the Mac's (Simplified Chinese when the first preferred language is Chinese written in simplified
/// characters, else English); headless — self-tests, `--snapshot-ui` — it is English unless `languageOverride` says
/// otherwise, so checks read the same on every Mac.
enum StudioText {
    /// Set by `--language` and by the self-tests; nil: the Mac's language (English headless).
    static var languageOverride: StudioLanguage?

    static var language: StudioLanguage {
        if let languageOverride { return languageOverride }
        if NSApp?.activationPolicy() == .prohibited { return .english }
        return macLanguage()
    }

    /// The Mac's language among those the Studio speaks.
    static func macLanguage(_ preferred: [String] = Locale.preferredLanguages) -> StudioLanguage {
        guard let first = preferred.first?.lowercased() else { return .english }
        if first.hasPrefix("zh-hans") { return .chinese }
        // Chinese without a script: simplified unless the region writes traditional characters.
        if first == "zh" || first.hasPrefix("zh-cn") || first.hasPrefix("zh-sg") { return .chinese }
        return .english
    }

    enum Key: String, CaseIterable {
        // The toolbar.
        case sidebar = "toolbar.sidebar"
        case showSidebar = "toolbar.sidebar.show"
        case hideSidebar = "toolbar.sidebar.hide"
        case undo = "toolbar.undo"
        case undoNamed = "toolbar.undo.named"
        case redo = "toolbar.redo"
        case redoNamed = "toolbar.redo.named"
        case undoRedo = "toolbar.undoRedo"
        case add = "toolbar.add"
        case addTip = "toolbar.add.tip"
        case code = "toolbar.code"
        case codeTip = "toolbar.code.tip"
        case addAndCode = "toolbar.addCode"
        case share = "toolbar.share"
        case shareLater = "toolbar.share.later"
        case done = "toolbar.done"
        case doneTip = "toolbar.done.tip"
        case placeOnDesktop = "toolbar.place"
        case inspector = "toolbar.inspector"
        case showInspector = "toolbar.inspector.show"
        case hideInspector = "toolbar.inspector.hide"
        case widgetName = "toolbar.name"
        case widgetNameTip = "toolbar.name.tip"
        // The copy sentence under the widget's name.
        case copyBuiltIn = "copy.builtIn"
        case copyBuiltInMany = "copy.builtIn.many"
        case copyEdited = "copy.edited"
        case copyFrom = "copy.from"
        case copyMadeByYou = "copy.madeByYou"
        case copyNew = "copy.new"
        case copyRainmeter = "copy.rainmeter"
        case copyConverted = "copy.converted"
        case copyNotLoaded = "copy.notLoaded"
        // Revert to Original.
        case revertToOriginal = "revert.title"
        case revertOne = "revert.one"
        case revertMany = "revert.many"
        case confirmReverted = "revert.confirm"
        // The popover the name opens.
        case runningTitle = "running.title"
        case runningFile = "running.file"
        case runningNothing = "running.nothing"
        case runningBuiltIn = "running.builtIn"
        case runningRainmeter = "running.rainmeter"
        case runningMadeByYou = "running.madeByYou"
        case symbolOf = "part.symbolOf"
        case clickThrough = "part.clickThrough"
        case showInFinder = "running.showInFinder"
        // The panes.
        case searchPlaceholder = "inspector.search"
        case tabAdd = "sidebar.add"
        case tabLayers = "sidebar.layers"
        case canvas = "canvas"
        case backdrop = "canvas.backdrop"
        // The canvas: backdrop, preview bar, zoom capsule, caption, capsules.
        case backdropDesktop = "backdrop.desktop"
        case backdropBright = "backdrop.bright"
        case backdropBusy = "backdrop.busy"
        case backdropDark = "backdrop.dark"
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
        case showOnDesktop = "zoom.showOnDesktop"
        case showOnDesktopShort = "zoom.showOnDesktop.short"
        case showOnDesktopTip = "zoom.showOnDesktop.tip"
        case captionOnDesktop = "caption.onDesktop"
        case captionNotOnDesktop = "caption.notOnDesktop"
        case captionActualSize = "caption.actualSize"
        case sizeSmall = "size.small"
        case sizeMedium = "size.medium"
        case sizeLarge = "size.large"
        case desktopAsItIs = "desktop.asItIs"
        case backToStudio = "desktop.back"
        case escapeKey = "desktop.esc"
        case showingDesktop = "desktop.announce"
        // The inspector's pages.
        case sourceOption = "page.source.option"
        case sourceLive = "page.source.live"
        case sourceRule = "page.source.rule"
        case sourceStyle = "page.source.style"
        case invalidValue = "page.invalid"
        case selected = "page.selected"
        case textSmaller = "page.textSmaller"
        case textBigger = "page.textBigger"
        case sectionOptions = "widget.options"
        case sectionShows = "widget.shows"
        case sectionColors = "widget.colors"
        case sectionFonts = "widget.fonts"
        case sectionFontsAndSize = "widget.fontsAndSize"
        case sectionLookAndSize = "widget.lookAndSize"
        case fontNumbers = "widget.font.numbers"
        case fontLabels = "widget.font.labels"
        case fontWords = "widget.font.words"
        case fontThisWidget = "widget.font.thisWidget"
        case fontMac = "widget.font.mac"
        case size = "widget.size"
        case sizeSmallShort = "widget.size.small"
        case sizeMediumShort = "widget.size.medium"
        case sizeLargeShort = "widget.size.large"
        case sizeLater = "widget.size.later"
        case lookAuto = "widget.look.auto"
        case lookLight = "widget.look.light"
        case lookDark = "widget.look.dark"
        case lookClear = "widget.look.clear"
        case lookShared = "widget.look.shared"
        case lookSharedBuiltIn = "widget.look.sharedBuiltIn"
        case lookScopeThis = "widget.look.scopeThis"
        case lookScopeAll = "widget.look.scopeAll"
        case lookScopeAllBuiltIn = "widget.look.scopeAllBuiltIn"
        case lookScopeOnlyThis = "widget.look.scopeOnlyThis"
        case swatchText = "widget.swatch.text"
        case swatchCard = "widget.swatch.card"
        case swatchMore = "widget.swatch.more"
        case followTheLook = "widget.followTheLook"
        case partsOne = "widget.parts.one"
        case partsMany = "widget.parts.many"
        case paints = "widget.paints"
        case moreSettings = "widget.moreSettings"
        case moreSettingsDetail = "widget.moreSettings.detail"
        case allOptions = "widget.allOptions"
        case allVariables = "widget.allVariables"
        case allData = "widget.allData"
        case moreColorsTitle = "widget.moreColors"
        case showsRing = "widget.shows.ring"
        case showsBar = "widget.shows.bar"
        case showsGraph = "widget.shows.graph"
        case showsGauge = "widget.shows.gauge"
        case showsShape = "widget.shows.shape"
        case showsOnlyThis = "widget.shows.onlyThis"
        case clock = "widget.clock"
        case hours12 = "widget.hours12"
        case hours24 = "widget.hours24"
        case unitsAuto = "widget.units.auto"
        case onLabel = "widget.on"
        case refreshSecond = "widget.refresh.second"
        case refreshTwoSeconds = "widget.refresh.twoSeconds"
        case refreshMinute = "widget.refresh.minute"
        case undoRefresh = "undo.refresh"
        case confirmRefresh = "confirm.refresh"
        // Undo names and the confirmations under a changed control.
        case undoColor = "undo.color"
        case undoFont = "undo.font"
        case undoTextSize = "undo.textSize"
        case undoLook = "undo.look"
        case undoSize = "undo.size"
        case undoShows = "undo.shows"
        case undoOption = "undo.option"
        case confirmColor = "confirm.color"
        case confirmFont = "confirm.font"
        case confirmBigger = "confirm.bigger"
        case confirmSmaller = "confirm.smaller"
        case confirmLook = "confirm.look"
        case confirmSize = "confirm.size"
        case confirmShows = "confirm.shows"
        case confirmOption = "confirm.option"
        case confirmUndo = "confirm.undo"
        // The color popover.
        case colorInWidget = "color.inWidget"
        case colorMac = "color.mac"
        case colorAccent = "color.accent"
        case colorRecent = "color.recent"
        case colorOpacity = "color.opacity"
        case colorMore = "color.more"
        case colorEyedropper = "color.eyedropper"
        case colorHex = "color.hex"
        case colorPartsOne = "color.parts.one"
        case colorPartsMany = "color.parts.many"
        case colorBadValue = "color.badValue"
        // The status menu.
        case useNewStudio = "menu.useNewStudio"
        case studioWindow = "window.studio"
        // The part page, Every Setting and the data page.
        case backTo = "part.backTo"
        case scrubTip = "part.scrubTip"
        case scopeOnly = "scope.only"
        case scopeApplyAll = "scope.applyAll"
        case scopeAll = "scope.all"
        case scopeOnlyThis = "scope.onlyThis"
        case scopeShareStyle = "scope.shareStyle"
        case scopeShareValue = "scope.shareValue"
        case scopeWidgets = "scope.widgets"
        case scopeWidgetsLink = "scope.widgetsLink"
        case scopeSharedPart = "scope.sharedPart"
        case sharedPartsKept = "widget.sharedPartsKept"
        case scopeDetailOnly = "scope.detail.only"
        case scopeDetailStyle = "scope.detail.style"
        case scopeDetailVariable = "scope.detail.variable"
        case scopeDetailFile = "scope.detail.file"
        case dragKeepsNotation = "part.dragKeepsNotation"
        case calculatedValue = "part.calculatedValue"
        case calculatedNote = "part.calculatedNote"
        case calculatedSize = "part.calculatedSize"
        case wordsElsewhere = "part.wordsElsewhere"
        case kindNumber = "kind.number"
        case kindNumbers = "kind.numbers"
        case kindText = "kind.text"
        case kindTexts = "kind.texts"
        case kindSymbol = "kind.symbol"
        case kindSymbols = "kind.symbols"
        case kindPicture = "kind.picture"
        case kindPictures = "kind.pictures"
        case kindBar = "kind.bar"
        case kindBars = "kind.bars"
        case kindRing = "kind.ring"
        case kindRings = "kind.rings"
        case kindGraph = "kind.graph"
        case kindGraphs = "kind.graphs"
        case kindShape = "kind.shape"
        case kindShapes = "kind.shapes"
        case kindPart = "kind.part"
        case kindParts = "kind.parts"
        case nowValue = "part.now"
        case subtitleOf = "part.subtitleOf"
        case subtitleSays = "part.subtitleSays"
        case subtitleKind = "part.subtitleKind"
        case everySettingCount = "part.everySettingCount"
        case sectionText = "section.text"
        case sectionLayout = "section.layout"
        case sectionClicked = "section.clicked"
        case sectionLook = "section.look"
        case sectionSymbol = "section.symbol"
        case sectionPicture = "section.picture"
        case sectionShape = "section.shape"
        case sectionFillStroke = "section.fillStroke"
        case rowStyle = "row.style"
        case rowFont = "row.font"
        case rowTextSize = "row.textSize"
        case rowWeight = "row.weight"
        case rowColor = "row.color"
        case rowAlign = "row.align"
        case rowX = "row.x"
        case rowY = "row.y"
        case rowSize = "row.size"
        case rowFill = "row.fill"
        case rowTrack = "row.track"
        case rowThickness = "row.thickness"
        case rowKind = "row.kind"
        case rowCorners = "row.corners"
        case rowStroke = "row.stroke"
        case rowStrokeWidth = "row.strokeWidth"
        case rowPicture = "row.picture"
        case rowTint = "row.tint"
        case rowSymbolColors = "row.symbolColors"
        case textColor = "part.textColor"
        case followsLightDark = "part.followsLightDark"
        case fit = "part.fit"
        case widthPrefix = "part.w"
        case heightPrefix = "part.h"
        case alignLeft = "align.left"
        case alignCenter = "align.center"
        case alignRight = "align.right"
        case afterPart = "part.after"
        case belowPart = "part.below"
        case withPart = "part.with"
        case clickNothing = "click.nothing"
        case clickRemove = "click.remove"
        case noStyle = "part.noStyle"
        case showsTitle = "part.showsTitle"
        case dataDetails = "part.dataDetails"
        case everySetting = "part.everySetting"
        case everySettingMore = "part.everySettingMore"
        case showInCode = "part.showInCode"
        case filterPlaceholder = "part.filter"
        case filterViaRainmeter = "part.filter.rainmeter"
        case filterViaAlias = "part.filter.alias"
        case boxMargin = "box.margin"
        case boxShadow = "box.shadow"
        case boxBackground = "box.background"
        case boxBorder = "box.border"
        case boxPadding = "box.padding"
        case boxNone = "box.none"
        case boxRaised = "box.raised"
        case boxSunken = "box.sunken"
        case boxOrder = "box.order"
        case voiceOver = "spoken.voiceOver"
        case dataUsedBy = "data.usedBy"
        case dataNotUsed = "data.notUsed"
        case dataLive = "data.live"
        case dataEvery = "data.every"
        case undoWeight = "undo.weight"
        case undoAlign = "undo.align"
        case undoPosition = "undo.position"
        case undoFormat = "undo.format"
        case undoClick = "undo.click"
        case undoStyle = "undo.style"
        case undoMove = "undo.move"
        case undoHide = "undo.hide"
        case undoShape = "undo.shape"
        case undoSetting = "undo.setting"
        case undoPartSize = "undo.partSize"
        case confirmMoved = "confirm.moved"
        case confirmHidden = "confirm.hidden"
        case confirmReset = "confirm.reset"
        case confirmWide = "confirm.wide"
        case optionDistances = "canvas.optionDistances"
        case menuHide = "canvas.hide"
        case menuShowPart = "canvas.show"
        case partsCount = "part.partsCount"
        // Step 5: the sidebar, Rainmeter details, the compatibility capsule, accessibility.
        case roleButton = "ax.roleButton"
        case freeLayout = "layers.freeLayout"
        case axWidget = "ax.widget"
        case axHidden = "ax.hidden"
        case axLocked = "ax.locked"
        case axProblem = "ax.problem"
        case issueWindowsPlugin = "issue.windowsPlugin"
        case issueWindowsData = "issue.windowsData"
        case issueWindowsProgram = "issue.windowsProgram"
        case findLayer = "layers.find"
        case measuresGroup = "layers.measures"
        case dataGroup = "layers.data"
        case dataUsedByTag = "layers.usedBy"
        case dataUnusedTag = "layers.unused"
        case noLayersFound = "layers.noneFound"
        case layersEmpty = "layers.empty"
        case rainmeterNamesOn = "details.on"
        case rainmeterNamesHidden = "details.off"
        case rainmeterNamesShown = "details.shown"
        case showRainmeterDetails = "details.menu"
        case compatOffer = "compat.offer"
        case compatSwitch = "compat.switch"
        case compatSwitchLater = "compat.switchLater"
        case compatStay = "compat.stay"
        case compatTip = "compat.tip"
        case stepOrder = "step.order"
        case stepShow = "step.show"
        case stepDelete = "step.delete"
        case stepAdd = "step.add"
        case stepForward = "step.forward"
        case stepBackward = "step.backward"
        case layerHide = "layers.hide"
        case layerShow = "layers.show"
        case layerLock = "layers.lock"
        case layerUnlock = "layers.unlock"
        case layerLockTip = "layers.lockTip"
        case layerDifferentFiles = "layers.differentFiles"
        case confirmShown = "confirm.shown"
        case confirmDeleted = "confirm.deleted"
        case confirmAdded = "confirm.added"
        case axDelete = "ax.delete"
        case axBringForward = "ax.bringForward"
        case axSendBackward = "ax.sendBackward"
        case axInCanvas = "ax.inCanvas"
        case rotorProblems = "ax.problems"
        case announceOpen = "ax.open"
        case announceOpenBuild = "ax.openBuild"
        case announceUndo = "ax.undo"
        case announceRedo = "ax.redo"
        case announceScope = "ax.scope"
        case addSearch = "add.search"
        case addShowData = "add.showData"
        case addThisMac = "add.thisMac"
        case addParts = "add.parts"
        case addSymbols = "add.symbols"
        case addBrowse = "add.browse"
        case addThisWidget = "add.thisWidget"
        case addTime = "add.time"
        case addWeather = "add.weather"
        case addMusic = "add.music"
        case addText = "add.text"
        case addSymbol = "add.symbol"
        case addPicture = "add.picture"
        case addButton = "add.button"
        case addNumber = "add.number"
        case addNothing = "add.nothing"
        case addHowTo = "add.howTo"
        case addClickOne = "add.clickOne"
        case addCancel = "add.cancel"
        case addPageTip = "add.tip"
        case addFontTip = "add.fontTip"
        case addColorTip = "add.colorTip"
        case addUnavailable = "add.unavailable"
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
        case codeNoSection = "code.noSection"
        case codeInspectorTip = "code.inspector.tip"
        case statusSaved = "code.status.saved"
        case statusHeld = "code.status.held"
        case statusNotSaved = "code.status.notSaved"
        case statusEditing = "code.status.editing"
        case statusLine = "code.status.line"
        case fix = "code.fix"
        case stepTyping = "step.typing"
        case stepFix = "step.fix"
        case stepRefresh = "step.refresh"
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
        case logClear = "log.clear"
        case menuFile = "menu.file"
        case menuEdit = "menu.edit"
        case menuInsert = "menu.insert"
        case menuArrange = "menu.arrange"
        case menuView = "menu.view"
        case menuWidget = "menu.widget"
        case menuWindow = "menu.window"
        case menuHelp = "menu.help"
        case menuClose = "menu.close"
        case menuSave = "menu.save"
        case menuShare = "menu.share"
        case menuUndo = "menu.undo"
        case menuRedo = "menu.redo"
        case menuCut = "menu.cut"
        case menuCopy = "menu.copy"
        case menuPaste = "menu.paste"
        case menuDuplicate = "menu.duplicate"
        case menuDelete = "menu.delete"
        case menuSelectAll = "menu.selectAll"
        case menuFind = "menu.find"
        case menuFindChange = "menu.find.change"
        case menuFindNext = "menu.find.next"
        case menuFindPrevious = "menu.find.previous"
        case menuData = "menu.data"
        case menuShape = "menu.shape"
        case menuAlign = "menu.align"
        case menuDistribute = "menu.distribute"
        case alignLeftEdges = "align.leftEdges"
        case alignCenterX = "align.centerX"
        case alignRightEdges = "align.rightEdges"
        case alignTop = "align.top"
        case alignCenterY = "align.centerY"
        case alignBottom = "align.bottom"
        case distributeX = "distribute.x"
        case distributeY = "distribute.y"
        case alignWidgetsHint = "align.widgetsHint"
        case arrangeWidgetsLater = "align.arrangeLater"
        case menuTextBigger = "menu.textBigger"
        case creditRainmeter = "widget.creditRainmeter"
        case clockNoAuto = "widget.clockNoAuto"
        case clockFrom = "widget.clockFrom"
        case announceDone = "announce.done"
        case codeNotSavedTitle = "code.notSaved.title"
        case codeNotSavedTheCode = "code.notSaved.theCode"
        case codeNotSavedInfo = "code.notSaved.info"
        case codeNotSavedSave = "code.notSaved.save"
        case codeNotSavedCancel = "code.notSaved.cancel"
        case codeNotSavedDiscard = "code.notSaved.discard"
        case menuTextSmaller = "menu.textSmaller"
        case menuRevertCount = "menu.revertCount"
        case zoomToSelection = "zoom.selection"
        case arrangeWidgets = "menu.arrangeWidgets"
        case stepAlign = "step.align"
        case stepDistribute = "step.distribute"
        case stepDuplicate = "step.duplicate"
        case menuShowAdd = "menu.view.add"
        case menuShowLayers = "menu.view.layers"
        case menuDesignOnly = "menu.view.designOnly"
        case menuCodeAlongside = "menu.view.codeAlongside"
        case menuCodeOnly = "menu.view.codeOnly"
        case menuEverySetting = "menu.view.everySetting"
        case menuShowInCode = "menu.view.showInCode"
        case menuRainmeterDetails = "menu.view.rainmeter"
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

    /// English, then Simplified Chinese. `%@` and `%d` are filled by `format`.
    static let table: [Key: (en: String, zh: String)] = [
        .sidebar: ("Sidebar", "侧栏"),
        .showSidebar: ("Show Sidebar", "显示侧栏"),
        .hideSidebar: ("Hide Sidebar", "隐藏侧栏"),
        .undo: ("Undo", "撤销"),
        .undoNamed: ("Undo %@", "撤销 %@"),
        .redo: ("Redo", "重做"),
        .redoNamed: ("Redo %@", "重做 %@"),
        .undoRedo: ("Undo", "撤销"),
        .add: ("Add", "添加"),
        .addTip: ("Add parts and data", "添加部件和数据"),
        .code: ("Code", "代码"),
        .codeTip: ("Show the code next to the widget", "在小组件旁边显示代码"),
        .addAndCode: ("Add and Code", "添加和代码"),
        .share: ("Share", "共享"),
        .shareLater: ("Sharing comes in a later version", "以后的版本可以共享"),
        .done: ("Done", "完成"),
        .doneTip: ("Every change is already saved. Closes the Studio.", "每一步都已存储。关闭 Studio。"),
        .placeOnDesktop: ("Place on Desktop", "放到桌面"),
        .inspector: ("Inspector", "检查器"),
        .showInspector: ("Show Inspector", "显示检查器"),
        .hideInspector: ("Hide Inspector", "隐藏检查器"),
        .widgetName: ("Widget", "小组件"),
        .widgetNameTip: ("Which file runs on your desktop", "桌面上运行的是哪个文件"),
        .copyBuiltIn: ("Built-in widget · on your desktop", "内置小组件 · 在桌面上"),
        .copyBuiltInMany: ("Built-in widget · %d on your desktop", "内置小组件 · 桌面上有 %d 个"),
        .copyEdited: ("Edited by you · original kept", "你改过的 · 原来的还留着"),
        .copyFrom: ("From %@ · on your desktop", "来自 %@ · 在桌面上"),
        .copyMadeByYou: ("Made by you · on your desktop", "你做的 · 在桌面上"),
        .copyNew: ("New widget · not on your desktop yet", "新的小组件 · 还没放到桌面上"),
        .copyRainmeter: ("Rainmeter skin · compatibility mode", "Rainmeter 皮肤 · 兼容模式"),
        .copyConverted: ("Converted from %@’s Rainmeter skin", "由 %@ 的 Rainmeter 皮肤转换"),
        .copyNotLoaded: ("Not on your desktop right now", "现在不在桌面上"),
        .revertToOriginal: ("Revert to Original", "恢复为原件"),
        .revertOne: ("1 change", "1 处修改"),
        .revertMany: ("%d changes", "%d 处修改"),
        .confirmReverted: ("Back to the original", "已恢复为原件"),
        .runningTitle: ("Running on your desktop", "桌面上运行的"),
        .runningFile: ("%@", "%@"),
        .runningNothing: ("Nothing: the widget is not on your desktop right now.", "没有：这个小组件现在不在桌面上。"),
        .runningBuiltIn: ("A widget that comes with Deskset.", "Deskset 自带的小组件。"),
        .runningRainmeter: ("The skin’s own file: changes are written into it.", "皮肤自己的文件：改动写进这个文件。"),
        .runningMadeByYou: ("Your widget’s own file: changes are written into it.", "你的小组件自己的文件：改动写进这个文件。"),
        .symbolOf: ("%@ symbol", "%@符号"),
        .clickThrough: ("%@ · %@’s click", "%@ · %@的点按"),
        .showInFinder: ("Show in Finder", "在访达中显示"),
        .searchPlaceholder: ("What do you want to change?", "想改什么？"),
        .tabAdd: ("Add", "添加"),
        .tabLayers: ("Layers", "图层"),
        .canvas: ("Widget canvas", "小组件画布"),
        .backdrop: ("Backdrop", "背板"),
        .backdropDesktop: ("Your Desktop", "你的桌面"),
        .backdropBright: ("Bright", "明亮"),
        .backdropBusy: ("Busy", "繁杂"),
        .backdropDark: ("Dark", "深色"),
        .backdropWorkbench: ("Workbench", "工作台"),
        .backdropTransparent: ("Transparent", "透明棋盘"),
        .backdropSolid: ("Solid", "实色"),
        .backdropSimilar: ("Similar", "相似"),
        .backdropClose: ("Close to your wallpaper", "接近你的墙纸"),
        .backdropSimilarTip: ("macOS does not say which picture shows now; this is one of them.",
                              "macOS 不告诉我们现在显示的是哪一张，这是其中一张。"),
        .backdropCloseTip: ("Your wallpaper is in a place macOS asks about before it can be read, so a sample close to it stands in.",
                            "你的墙纸在需要 macOS 授权才能读取的地方，所以这里用一张接近的样例代替。"),
        .showOtherWidgets: ("Show Other Widgets", "显示其他小组件"),
        .previewBar: ("Preview", "预览"),
        .previewPrefix: ("Preview:", "预览："),
        .previewTip: ("How the widget looks in this window only", "只改这个窗口里的样子"),
        .lightMode: ("Light Mode", "浅色模式"),
        .darkMode: ("Dark Mode", "深色模式"),
        .live: ("Live", "实时"),
        .dataTip: ("Sample data and time, in this window only", "样例数据和时间，只在这个窗口里"),
        .interact: ("Interact", "互动预览"),
        .interactTip: ("Hover and click in the widget without leaving the Studio; clicks work as they do on the desktop",
                       "不离开 Studio，在组件里悬停和点按；点按会像在桌面上一样生效"),
        .backToLive: ("Back to Live", "回到实时"),
        .previewOnly: ("Preview only", "只是预览"),
        .macAppearance: ("Mac appearance", "Mac 的外观"),
        .followMac: ("Follow Mac", "跟随 Mac"),
        .appearanceLight: ("Light", "浅色"),
        .appearanceDark: ("Dark", "深色"),
        .glass: ("Glass", "玻璃"),
        .glassDefault: ("Default", "默认"),
        .glassClear: ("Clear", "更透"),
        .glassTinted: ("Tinted (Mac setting)", "着色（Mac 设置）"),
        .language: ("Language", "语言"),
        .previewFooter: ("Preview only — your widget doesn’t change.", "只改这个窗口里的样子，你的小组件不变。"),
        .dataHeader: ("Data", "数据"),
        .dataPaused: ("Paused", "暂停"),
        .dataLongText: ("Long Text", "很长的文字"),
        .dataNone: ("No Data", "没有数据"),
        .timeHeader: ("Time", "时间"),
        .timeFrozen: ("Frozen at %@", "冻结在 %@"),
        .timePick: ("Pick a Time…", "选一个时间…"),
        .timePickTitle: ("Show the widget at", "让小组件显示"),
        .timePickUse: ("Use This Time", "用这个时间"),
        .previewing: ("Previewing %@ · your desktop doesn’t change", "预览中：%@ · 桌面不变"),
        .previewingData: ("sample data %@", "样例数据 %@"),
        .previewingPaused: ("paused data", "暂停的数据"),
        .previewingLongText: ("long text", "很长的文字"),
        .previewingNoData: ("no data", "没有数据"),
        .previewingTime: ("the time %@", "时间 %@"),
        .wouldOpen: ("Would open %@", "会打开 %@"),
        .wouldOpenWidget: ("Would open another widget", "会打开另一个小组件"),
        .wouldCloseWidget: ("Would close a widget", "会关掉一个小组件"),
        .wouldSaveSetting: ("Would save a setting to its file", "会把一个设置存进文件"),
        .wouldChangeWindow: ("Would change the widget’s window on the desktop", "会改动桌面上组件的窗口"),
        .wouldRunCommand: ("Would run a command", "会执行一个命令"),
        .wouldUseDeskset: ("Would ask Deskset to do something", "会让 Deskset 做一件事"),
        .wouldActOutside: ("Would act outside the widget", "会作用到组件以外"),
        .wouldChange: ("Would change %@", "会改动 %@"),
        .open: ("Open", "打开"),
        .run: ("Run", "执行"),
        .zoomCapsule: ("Zoom", "缩放"),
        .zoomIn: ("Zoom In", "放大"),
        .zoomOut: ("Zoom Out", "缩小"),
        .zoomToFit: ("Zoom to Fit", "缩放到合适"),
        .actualSize: ("Actual Size", "实际大小"),
        .actualSizeShort: ("1:1", "1:1"),
        .showOnDesktop: ("Show on Desktop", "看桌面"),
        .showOnDesktopShort: ("Desktop", "看桌面"),
        .showOnDesktopTip: ("The widget on your desktop, as it is now. Press to switch; hold ⇧⌘D to peek.",
                            "桌面上真的那一份。按一下切换；按住 ⇧⌘D 偷看。"),
        .captionOnDesktop: ("Preview %@ · %@ on your desktop", "预览 %@ · 桌面上是%@"),
        .captionNotOnDesktop: ("Preview %@ · %@ · not on your desktop yet", "预览 %@ · %@，还没放到桌面上"),
        .captionActualSize: ("Actual size · where it is on your desktop", "实际大小 · 它在你桌面上的位置"),
        .sizeSmall: ("Small", "小号"),
        .sizeMedium: ("Medium", "中号"),
        .sizeLarge: ("Large", "大号"),
        .desktopAsItIs: ("Your desktop, as it is now", "这就是你现在的桌面"),
        .backToStudio: ("Back to Studio", "回到 Studio"),
        .escapeKey: ("Esc", "Esc"),
        .showingDesktop: ("Showing the desktop. Press Escape to go back.", "正在显示桌面，按 Esc 返回。"),
        .sourceOption: ("Option", "选项"),
        .sourceLive: ("Live", "实时"),
        .sourceRule: ("Rule", "规则"),
        .sourceStyle: ("Style", "样式"),
        .invalidValue: ("Written as “%@”, which this can’t show", "写的是“%@”，这里显示不了"),
        .selected: ("Selected", "已选中"),
        .textSmaller: ("Make All Text Smaller", "缩小全部文字"),
        .textBigger: ("Make All Text Bigger", "放大全部文字"),
        .sectionOptions: ("Options", "选项"),
        .sectionShows: ("Shows", "显示内容"),
        .sectionColors: ("Colors", "颜色"),
        .sectionFonts: ("Fonts", "字体"),
        .sectionFontsAndSize: ("Fonts and size", "字体和大小"),
        .sectionLookAndSize: ("Look and size", "外观和大小"),
        .fontNumbers: ("Numbers", "数字"),
        .fontLabels: ("Labels", "文字"),
        .fontWords: ("Words", "文字"),
        .fontThisWidget: ("In This Widget", "这个小组件的字体"),
        .fontMac: ("Mac Fonts", "Mac 字体"),
        .size: ("Size", "大小"),
        .sizeSmallShort: ("Small", "小"),
        .sizeMediumShort: ("Medium", "中"),
        .sizeLargeShort: ("Large", "大"),
        .sizeLater: ("Scaling a whole widget comes in a later version", "整体缩放在以后的版本里提供"),
        .lookAuto: ("Auto", "自动"),
        .lookLight: ("Light", "浅色"),
        .lookDark: ("Dark", "深色"),
        .lookClear: ("Clear", "透明"),
        .lookShared: ("Shared by all %d %@ widgets", "全部 %d 个 %@ 小组件共用这个外观"),
        .lookSharedBuiltIn: ("Shared by all %d built-in widgets", "全部 %d 个内置小组件共用这个外观"),
        .lookScopeThis: ("This widget only", "只改这个小组件"),
        .lookScopeAll: ("All %d %@ widgets", "全部 %d 个 %@ 小组件"),
        .lookScopeAllBuiltIn: ("All %d built-in widgets", "全部 %d 个内置小组件"),
        .lookScopeOnlyThis: ("Only This Widget", "只改这一个小组件"),
        .swatchText: ("Text", "文字"),
        .swatchCard: ("Card", "卡片"),
        .swatchMore: ("More…", "更多…"),
        .followTheLook: ("follow the look", "跟随外观"),
        .partsOne: ("1 part", "1 个部件"),
        .partsMany: ("%d parts", "%d 个部件"),
        .paints: ("%@ · %@", "%@ · %@"),
        .moreSettings: ("More Settings", "更多设置"),
        .moreSettingsDetail: ("Clicks, updates, name", "点按、刷新、名称"),
        .allOptions: ("All Options (%d)…", "全部选项（%d 个）…"),
        .allVariables: ("All Variables (%d)…", "全部变量（%d 个）…"),
        .allData: ("All Data (%d)…", "全部数据（%d 个）…"),
        .moreColorsTitle: ("Every color in this widget", "这个小组件里的每一个颜色"),
        .showsRing: ("Ring", "圆环"),
        .showsBar: ("Bar", "进度条"),
        .showsGraph: ("Graph", "曲线"),
        .showsGauge: ("Gauge", "仪表"),
        .showsShape: ("Shape", "形状"),
        .showsOnlyThis: ("This part works out its own value: other data is changed in the code",
                         "这个部件自己算出数值：换别的数据要在代码里改"),
        .clock: ("Clock", "时钟"),
        .hours12: ("1:30 PM", "下午 1:30"),
        .hours24: ("13:30", "13:30"),
        .unitsAuto: ("Auto", "自动"),
        .onLabel: ("On", "开"),
        .refreshSecond: ("Refresh Every Second", "每 1 秒刷新"),
        .refreshTwoSeconds: ("Refresh Every 2 Seconds", "每 2 秒刷新"),
        .refreshMinute: ("Refresh Every Minute", "每分钟刷新"),
        .undoRefresh: ("Refresh", "刷新"),
        .confirmRefresh: ("Now: %@", "现在：%@"),
        .undoColor: ("Color", "颜色"),
        .undoFont: ("Font", "字体"),
        .undoTextSize: ("Text Size", "字号"),
        .undoLook: ("Look", "外观"),
        .undoSize: ("Size", "大小"),
        .undoShows: ("Shows", "显示内容"),
        .undoOption: ("%@", "%@"),
        .confirmColor: ("%@ is now %@", "%@已改为%@"),
        .confirmFont: ("%@ are now in %@", "%@已改为%@"),
        .confirmBigger: ("All text is bigger", "全部文字已放大"),
        .confirmSmaller: ("All text is smaller", "全部文字已缩小"),
        .confirmLook: ("The look is now %@", "外观已改为%@"),
        .confirmSize: ("Now %@ on your desktop", "桌面上现在是%@"),
        .confirmShows: ("%@ now shows %@", "%@现在显示%@"),
        .confirmOption: ("%@ is now %@", "%@已改为%@"),
        .confirmUndo: ("Undo", "撤销"),
        .colorInWidget: ("In this widget", "这个小组件的颜色"),
        .colorMac: ("Mac colors", "Mac 颜色"),
        .colorAccent: ("Accent · follows your Mac", "强调色 · 跟随你的 Mac"),
        .colorRecent: ("Recent", "最近"),
        .colorOpacity: ("Opacity", "不透明度"),
        .colorMore: ("More Colors…", "更多颜色…"),
        .colorEyedropper: ("Pick a color from the screen", "从屏幕上取色"),
        .colorHex: ("Color code", "色值"),
        .colorPartsOne: ("1 part in this widget", "这个小组件里 1 个部件"),
        .colorPartsMany: ("%d parts in this widget", "这个小组件里 %d 个部件"),
        .colorBadValue: ("Not a color: try #40BA5C", "不是颜色：试试 #40BA5C"),
        .useNewStudio: ("Use New Studio", "使用新的 Studio"),
        .studioWindow: ("Studio", "Studio"),
        .backTo: ("Back to %@", "返回%@"),
        .scrubTip: ("Drag to change · ⌥-click for the default", "拖动改值 · 按住 ⌥ 点按恢复默认"),
        .scopeOnly: ("This %@ only", "只改这个%@"),
        .scopeApplyAll: ("Apply to All %d %@", "应用到全部 %d 个%@"),
        .scopeAll: ("All %d %@", "全部 %d 个%@"),
        .scopeOnlyThis: ("Only This %@", "只改这一个%@"),
        .scopeShareStyle: ("%d %@ share one style", "%d 个%@共用一个样式"),
        .scopeShareValue: ("%d parts use this value", "%d 个部件用这个值"),
        .scopeWidgets: ("This widget · all %d", "这个小组件 · 全部 %d 个"),
        .scopeWidgetsLink: ("All %d Widgets", "全部 %d 个小组件"),
        .scopeSharedPart: ("This %@ comes from a file all %d widgets share", "这个%@来自全部 %d 个小组件共用的文件"),
        .sharedPartsKept: ("%@ comes from a file other widgets share and stays as it is",
                           "%@来自其他小组件共用的文件，保持不变"),
        .scopeDetailOnly: ("Only [%@]", "只改 [%@]"),
        .scopeDetailStyle: ("shared style %@ (%d meters)", "改共用样式 %@（%d 个 meter）"),
        .scopeDetailVariable: ("variable %@ (%d meters)", "改变量 %@（%d 个 meter）"),
        .scopeDetailFile: ("shared file %@ (%d widgets)", "改共用文件 %@（%d 个小组件）"),
        .dragKeepsNotation: ("Dragging keeps how it is written (%@ → %@)", "拖动保留写法（%@ → %@）"),
        .calculatedValue: ("%@ pt · calculated", "%@ 点 · 计算出的值"),
        .calculatedNote: ("Worked out from other values", "由其他值算出"),
        .calculatedSize: ("%@ × %@ pt · calculated", "%@ × %@ 点 · 计算出的值"),
        .wordsElsewhere: ("The widget's words, in each language", "小组件自己的文字，每种语言一份"),
        .kindNumber: ("number", "数字"),
        .kindNumbers: ("numbers", "数字"),
        .kindText: ("text", "文字"),
        .kindTexts: ("texts", "文字"),
        .kindSymbol: ("symbol", "符号"),
        .kindSymbols: ("symbols", "符号"),
        .kindPicture: ("picture", "图片"),
        .kindPictures: ("pictures", "图片"),
        .kindBar: ("bar", "进度条"),
        .kindBars: ("bars", "进度条"),
        .kindRing: ("ring", "圆环"),
        .kindRings: ("rings", "圆环"),
        .kindGraph: ("graph", "曲线"),
        .kindGraphs: ("graphs", "曲线"),
        .kindShape: ("shape", "形状"),
        .kindShapes: ("shapes", "形状"),
        .kindPart: ("part", "部件"),
        .kindParts: ("parts", "部件"),
        .nowValue: ("Now %@", "现在 %@"),
        .subtitleOf: ("the %2$@ %1$@", "%2$@ 的%1$@"),
        .subtitleSays: ("says “%@”", "写着“%@”"),
        .subtitleKind: ("a %@", "一个%@"),
        .everySettingCount: ("every setting · %d", "所有设置 · %d 项"),
        .sectionText: ("Text", "文字"),
        .sectionLayout: ("Layout", "排版"),
        .sectionClicked: ("When clicked", "点按时"),
        .sectionLook: ("Look", "外观"),
        .sectionSymbol: ("Symbol", "符号"),
        .sectionPicture: ("Picture", "图片"),
        .sectionShape: ("Shape", "形状"),
        .sectionFillStroke: ("Fill and stroke", "填充和描边"),
        .rowStyle: ("Shared style", "共用样式"),
        .rowFont: ("Font", "字体"),
        .rowTextSize: ("Text size", "字号"),
        .rowWeight: ("Weight", "字重"),
        .rowColor: ("Color", "颜色"),
        .rowAlign: ("Align", "对齐"),
        .rowX: ("X", "X"),
        .rowY: ("Y", "Y"),
        .rowSize: ("Size", "大小"),
        .rowFill: ("Fill", "填充"),
        .rowTrack: ("Track", "轨道"),
        .rowThickness: ("Thickness", "粗细"),
        .rowKind: ("Kind", "种类"),
        .rowCorners: ("Corners", "圆角"),
        .rowStroke: ("Stroke", "描边"),
        .rowStrokeWidth: ("Stroke width", "描边粗细"),
        .rowPicture: ("Picture", "图片"),
        .rowTint: ("Tint", "着色"),
        .rowSymbolColors: ("Colors", "颜色"),
        .textColor: ("Text color", "文字颜色"),
        .followsLightDark: ("follows Light/Dark", "跟随浅色 / 深色"),
        .fit: ("Fit", "跟随内容"),
        .widthPrefix: ("W", "宽"),
        .heightPrefix: ("H", "高"),
        .alignLeft: ("Left", "左对齐"),
        .alignCenter: ("Center", "居中"),
        .alignRight: ("Right", "右对齐"),
        .afterPart: ("after “%@”", "在“%@”后面"),
        .belowPart: ("below “%@”", "在“%@”下面"),
        .withPart: ("level with “%@”", "和“%@”对齐"),
        .clickNothing: ("Nothing happens", "什么都不做"),
        .clickRemove: ("Do Nothing When Clicked", "点按时什么都不做"),
        .noStyle: ("None", "无"),
        .showsTitle: ("Show", "显示"),
        .dataDetails: ("Data Details…", "数据详情…"),
        .everySetting: ("Every Setting", "所有设置"),
        .everySettingMore: ("%d more", "另有 %d 项"),
        .showInCode: ("Show in Code", "在代码中显示"),
        .filterPlaceholder: ("Filter these settings", "筛选这些设置"),
        .filterViaRainmeter: ("%@ · Rainmeter: %@", "%@ · Rainmeter：%@"),
        .filterViaAlias: ("%@ · “%@”", "%@ · “%@”"),
        .boxMargin: ("Margin %@", "外边距 %@"),
        .boxShadow: ("Shadow %@", "阴影 %@"),
        .boxBackground: ("Background %@", "背景 %@"),
        .boxBorder: ("Border %@", "边框 %@"),
        .boxPadding: ("Padding %@", "内边距 %@"),
        .boxNone: ("none", "无"),
        .boxRaised: ("raised", "凸起"),
        .boxSunken: ("sunken", "凹陷"),
        .boxOrder: ("outside → inside", "由外到内"),
        .voiceOver: ("VoiceOver", "VoiceOver"),
        .dataUsedBy: ("Used by", "谁在用"),
        .dataNotUsed: ("No part shows it", "没有部件显示它"),
        .dataLive: ("Live data", "实时数据"),
        .dataEvery: ("updates every %@", "每 %@ 更新"),
        .undoWeight: ("Weight", "字重"),
        .undoAlign: ("Alignment", "对齐"),
        .undoPosition: ("Position", "位置"),
        .undoFormat: ("Format", "格式"),
        .undoClick: ("Click", "点按"),
        .undoStyle: ("Shared Style", "共用样式"),
        .undoMove: ("Move", "移动"),
        .undoHide: ("Hide", "隐藏"),
        .undoShape: ("Shape", "形状"),
        .undoSetting: ("%@", "%@"),
        .undoPartSize: ("Size", "大小"),
        .confirmMoved: ("Moved %@", "已移动%@"),
        .confirmHidden: ("%@ is hidden", "%@已隐藏"),
        .confirmReset: ("%@ is back to its default", "%@已恢复默认"),
        .confirmWide: ("%@ · %d parts changed", "%@ · 改了 %d 个部件"),
        .optionDistances: ("⌥ shows distances", "按住 ⌥ 显示距离"),
        .menuHide: ("Hide %@", "隐藏%@"),
        .menuShowPart: ("Show %@", "显示%@"),
        .partsCount: ("%d parts", "%d 个部件"),
        .roleButton: ("button", "按钮"),
        .freeLayout: ("free layout", "自由摆放"),
        .axWidget: ("%@, the widget", "%@，小组件"),
        .axHidden: ("hidden", "已隐藏"),
        .axLocked: ("locked", "已锁定"),
        .axProblem: ("needs attention", "需要处理"),
        .issueWindowsPlugin: ("%@ reads 0: it comes from %@, which only runs on Windows", "%@ 显示 0：它来自只能在 Windows 上运行的 %@"),
        .issueWindowsData: ("%@ reads 0: it only works on Windows", "%@ 显示 0：它只能在 Windows 上用"),
        .issueWindowsProgram: ("“%@” opens a Windows program", "“%@”会打开一个 Windows 程序"),
        .findLayer: ("Find a layer", "查找图层"),
        .measuresGroup: ("Measures", "数据（measure）"),
        .dataGroup: ("Data", "数据"),
        .dataUsedByTag: ("%@ · used by %@", "%@ · %@在用"),
        .dataUnusedTag: ("%@ · not used", "%@ · 没有部件在用"),
        .noLayersFound: ("Nothing matches “%@”", "没有和“%@”相符的图层"),
        .layersEmpty: ("No parts yet: add one from Add", "还没有部件：从“添加”里加一个"),
        .rainmeterNamesOn: ("Rainmeter names on · ⌥⌘R to hide", "已显示 Rainmeter 名称 · ⌥⌘R 隐藏"),
        .rainmeterNamesHidden: ("Rainmeter names hidden", "已隐藏 Rainmeter 名称"),
        .rainmeterNamesShown: ("Rainmeter names shown", "已显示 Rainmeter 名称"),
        .showRainmeterDetails: ("Show Rainmeter Details", "显示 Rainmeter 细节"),
        .compatOffer: ("Also available as a Deskset widget: more Mac features, but you’d edit Desk instead of INI.", "也可以换成 Deskset 小组件：能用更多 Mac 功能，但以后改的是 Desk，不是 INI。"),
        .compatSwitch: ("Switch", "换过去"),
        .compatSwitchLater: ("Switching to a Deskset widget comes in a later version", "以后的版本可以换成 Deskset 小组件"),
        .compatStay: ("Stay with INI", "继续用 INI"),
        .compatTip: ("%@ stays a Rainmeter skin: changes are written into its .ini files.", "%@ 仍是 Rainmeter 皮肤：改动写进它的 .ini 文件。"),
        .stepOrder: ("Change Order", "更改顺序"),
        .stepShow: ("Show", "显示"),
        .stepDelete: ("Delete", "删除"),
        .stepAdd: ("Add %@", "添加 %@"),
        .stepForward: ("Bring Forward", "前移"),
        .stepBackward: ("Send Backward", "后移"),
        .layerHide: ("Hide", "隐藏"),
        .layerShow: ("Show", "显示"),
        .layerLock: ("Lock", "锁定"),
        .layerUnlock: ("Unlock", "解锁"),
        .layerLockTip: ("Lock it so it can’t be moved by accident", "锁定，免得不小心移动"),
        .layerDifferentFiles: ("These parts are in different files, so their order can’t change here", "这些部件在不同的文件里，这里改不了它们的顺序"),
        .confirmShown: ("%@ shows again", "%@又显示了"),
        .confirmDeleted: ("%@ deleted", "%@已删除"),
        .confirmAdded: ("Added %@", "已添加 %@"),
        .axDelete: ("Delete", "删除"),
        .axBringForward: ("Bring Forward", "前移"),
        .axSendBackward: ("Send Backward", "后移"),
        .axInCanvas: ("in %@", "在 %@ 里"),
        .rotorProblems: ("Problems", "问题"),
        .announceOpen: ("Customizing “%@”. The inspector shows the widget page.", "正在自定“%@”。检查器显示小组件页。"),
        .announceOpenBuild: ("Building “%@”. The sidebar shows its layers.", "正在搭建“%@”。侧栏显示它的图层。"),
        .announceUndo: ("Undid %@", "已撤销 %@"),
        .announceRedo: ("Redid %@", "已重做 %@"),
        .announceScope: ("Now changing: %@", "现在改的是：%@"),
        .addSearch: ("Data, parts, symbols", "数据、部件、符号"),
        .addShowData: ("Show data", "显示数据"),
        .addThisMac: ("This Mac", "这台 Mac"),
        .addParts: ("Parts", "部件"),
        .addSymbols: ("Symbols", "符号"),
        .addBrowse: ("Browse…", "浏览…"),
        .addThisWidget: ("In this widget", "这个组件里的"),
        .addTime: ("Time", "时间"),
        .addWeather: ("Weather", "天气"),
        .addMusic: ("Music", "音乐"),
        .addText: ("Text", "文字"),
        .addSymbol: ("Symbol", "符号"),
        .addPicture: ("Picture", "图片"),
        .addButton: ("Button", "按钮"),
        .addNumber: ("Number", "数字"),
        .addNothing: ("Nothing matches “%@”", "没有和“%@”相符的"),
        .addHowTo: ("Show %@ as…", "把%@显示成…"),
        .addClickOne: ("Click one to add it", "点一种就加上"),
        .addCancel: ("Cancel", "取消"),
        .addPageTip: ("Click to add after the selection, or drag onto the widget", "点按加在选中的后面，或拖到小组件上"),
        .addFontTip: ("Drag onto a text to use this font", "拖到文字上就用这个字体"),
        .addColorTip: ("Drag onto a part to use this color", "拖到部件上就用这个颜色"),
        .addUnavailable: ("Not on this Mac", "这台 Mac 上没有"),
        .codePane: ("Code", "代码"),
        .codeFileTip: ("The widget’s files: the main one and every file it includes", "组件的文件：主文件和它包含的每个文件"),
        .codeOpenIn: ("Open in %@", "在 %@ 中打开"),
        .codeLog: ("Log %d", "日志 %d"),
        .codeLogTip: ("What the widget logged (Window ▸ Log)", "组件记下的日志（窗口 ▸ 日志）"),
        .codeMore: ("More", "更多"),
        .codeProblems: ("%d problem", "%d 个问题"),
        .codeProblemsMany: ("%d problems", "%d 个问题"),
        .codeWarnings: ("%d warning", "%d 个提醒"),
        .codeWarningsMany: ("%d warnings", "%d 个提醒"),
        .codeProblemsTip: ("Can’t draw: the next one", "画不出来：下一个"),
        .codeWarningsTip: ("Still draws, with a default: the next one", "还能画，用的是默认值：下一个"),
        .codeNoSection: ("No section", "不在任何节里"),
        .codeInspectorTip: ("Back to the inspector (the code goes)", "换回检查器（代码收起）"),
        .statusSaved: ("Saved · your desktop is updated", "已存储 · 桌面上已更新"),
        .statusHeld: ("Saved · your desktop keeps the last working version until the red problem is fixed", "已存储 · 红色问题修好之前，桌面上保留上一次能用的版本"),
        .statusNotSaved: ("Not saved: %@", "没有存储：%@"),
        .statusEditing: ("Editing · saved when you pause", "正在编辑 · 停下来就存储"),
        .statusLine: ("Line %d", "第 %d 行"),
        .fix: ("Fix", "改正"),
        .stepTyping: ("Typing", "输入"),
        .stepFix: ("Fix %@", "改正 %@"),
        .stepRefresh: ("Refresh", "刷新"),
        .diagUnknownMeterKey: ("%@ isn’t an option of a %@ meter. Did you mean %@?", "%@ 不是 %@ meter 的选项，是不是想写 %@？"),
        .diagUnknownMeasureKey: ("%@ isn’t an option of a %@ measure. Did you mean %@?", "%@ 不是 %@ measure 的选项，是不是想写 %@？"),
        .diagMeanwhileColorMany: ("The %@ draw in the default %@ until then.", "改正之前，%@按默认的%@画。"),
        .diagMeanwhileColorOne: ("The %@ draws in the default %@ until then.", "改正之前，%@按默认的%@画。"),
        .diagMeanwhileDefault: ("Until then the default %@ applies.", "改正之前用默认的 %@。"),
        .diagBadColor: ("%@ isn’t a color: write R,G,B or RRGGBB.", "%@ 不是颜色：要写 R,G,B 或 RRGGBB。"),
        .diagBadFormula: ("%@ can’t be worked out: %@.", "%@ 算不出来：%@。"),
        .diagMissingNumber: ("a number is missing after “%@”", "“%@”后面少了一个数"),
        .diagMissingParen: ("a “)” is missing", "少了一个“)”"),
        .diagUnknownFunction: ("there’s no function %@", "没有 %@ 这个函数"),
        .diagEmptyFormula: ("there’s nothing in it", "里面什么也没有"),
        .diagCantDrawMany: ("The %d %@ don’t draw.", "%d 个%@画不出来。"),
        .diagCantDrawOne: ("The %@ doesn’t draw.", "%@画不出来。"),
        .diagMissingMeasure: ("There’s no measure called %@.", "没有叫 %@ 的 measure。"),
        .diagMissingStyle: ("There’s no section called %@ to use as a style.", "没有叫 %@ 的节可以当样式。"),
        .diagMissingInclude: ("%@ isn’t there, so nothing in it is read.", "找不到 %@，它里面的内容都读不到。"),
        .diagMissingImage: ("There’s no picture at %@.", "%@ 这里没有图片。"),
        .diagUnknownBang: ("%@ isn’t a bang. Did you mean %@?", "%@ 不是 bang，是不是想写 %@？"),
        .diagUnknownBangNoGuess: ("%@ isn’t a bang Rainmeter knows.", "Rainmeter 不认识 %@ 这个 bang。"),
        .diagBlack: ("black", "黑色"),
        .diagWhite: ("white", "白色"),
        .diagColor: ("color", "颜色"),
        .nounBar: ("bar", "进度条"),
        .nounBars: ("bars", "进度条"),
        .nounText: ("text", "文字"),
        .nounTexts: ("texts", "文字"),
        .nounNumber: ("number", "数字"),
        .nounNumbers: ("numbers", "数字"),
        .nounPicture: ("picture", "图片"),
        .nounPictures: ("pictures", "图片"),
        .nounGraph: ("graph", "曲线"),
        .nounGraphs: ("graphs", "曲线"),
        .nounRing: ("ring", "圆环"),
        .nounRings: ("rings", "圆环"),
        .nounHand: ("hand", "指针"),
        .nounHands: ("hands", "指针"),
        .nounButton: ("button", "按钮"),
        .nounButtons: ("buttons", "按钮"),
        .nounShape: ("shape", "形状"),
        .nounShapes: ("shapes", "形状"),
        .nounPart: ("part", "部件"),
        .nounParts: ("parts", "部件"),
        .capsuleCantDraw: ("The %@ can’t draw", "%@画不出来"),
        .capsuleCantDrawNamed: ("%@ can’t draw", "%@画不出来"),
        .capsuleKeeps: ("your desktop keeps the last working version", "桌面上保留上一次能用的版本"),
        .capsuleProblems: ("%d problem · the rest still draws", "%d 个问题 · 其余照常显示"),
        .capsuleProblemsMany: ("%d problems · the rest still draws", "%d 个问题 · 其余照常显示"),
        .logTitle: ("Log", "日志"),
        .logTitleWidget: ("Log · %@", "日志 · %@"),
        .logThisWidget: ("This Widget", "这个小组件"),
        .logAllWidgets: ("All Widgets", "全部小组件"),
        .logAllLevels: ("All", "全部"),
        .logErrors: ("Errors", "错误"),
        .logWarnings: ("Warnings", "警告"),
        .logInfo: ("Information", "信息"),
        .logEmpty: ("Nothing logged", "没有日志"),
        .logShowLine: ("Show the Line", "跳到那一行"),
        .logStudio: ("In the Studio", "在 Studio 里"),
        .logDesktop: ("On the desktop", "在桌面上"),
        .logClear: ("Clear", "清除"),
        .menuFile: ("File", "文件"),
        .menuEdit: ("Edit", "编辑"),
        .menuInsert: ("Insert", "插入"),
        .menuArrange: ("Arrange", "排列"),
        .menuView: ("View", "显示"),
        .menuWidget: ("Widget", "小组件"),
        .menuWindow: ("Window", "窗口"),
        .menuHelp: ("Help", "帮助"),
        .menuClose: ("Close", "关闭"),
        .menuSave: ("Save", "存储"),
        .menuShare: ("Share…", "共享…"),
        .menuUndo: ("Undo", "撤销"),
        .menuRedo: ("Redo", "重做"),
        .menuCut: ("Cut", "剪切"),
        .menuCopy: ("Copy", "拷贝"),
        .menuPaste: ("Paste", "粘贴"),
        .menuDuplicate: ("Duplicate", "复制"),
        .menuDelete: ("Delete", "删除"),
        .menuSelectAll: ("Select All", "全选"),
        .menuFind: ("Find", "查找"),
        .menuFindChange: ("What Do You Want to Change?", "想改什么？"),
        .menuFindNext: ("Find Next", "查找下一个"),
        .menuFindPrevious: ("Find Previous", "查找上一个"),
        .menuData: ("Data…", "数据…"),
        .menuShape: ("Shape", "形状"),
        .menuAlign: ("Align", "对齐"),
        .menuDistribute: ("Distribute", "分布"),
        .alignLeftEdges: ("Left Edges", "左边缘"),
        .alignCenterX: ("Centers", "水平居中"),
        .alignRightEdges: ("Right Edges", "右边缘"),
        .alignTop: ("Top Edges", "顶边缘"),
        .alignCenterY: ("Middles", "垂直居中"),
        .alignBottom: ("Bottom Edges", "底边缘"),
        .distributeX: ("Horizontally", "水平"),
        .distributeY: ("Vertically", "垂直"),
        .alignWidgetsHint: ("To line up widgets on your desktop, use Arrange Widgets", "要对齐桌面上的几个小组件，请用“整理小组件”"),
        .arrangeWidgets: ("Arrange Widgets…", "整理小组件…"),
        .arrangeWidgetsLater: ("Arrange Widgets comes in a later version: for now, drag the widgets on your desktop",
                               "“整理小组件”会在以后的版本里加入：现在请在桌面上拖动小组件"),
        .menuTextBigger: ("Make Text Bigger", "放大文字"),
        .creditRainmeter: ("From %@’s Rainmeter skin", "来自%@的 Rainmeter 皮肤"),
        .clockNoAuto: ("A Rainmeter skin’s time format can’t follow the Mac’s own setting: choose 12 or 24 hours",
                       "Rainmeter 皮肤的时间格式无法跟随 Mac 的设置：请选 12 小时或 24 小时"),
        .clockFrom: ("from %@", "取自 %@"),
        .announceDone: ("Saved. Closing the Studio.", "已存储。正在关闭 Studio。"),
        .codeNotSavedTitle: ("Your changes to %@ couldn’t be saved", "你对%@的修改无法存储"),
        .codeNotSavedTheCode: ("the code", "代码"),
        .codeNotSavedInfo: ("Save tries again. If you discard them, the files stay as they are on disk.",
                            "“存储”会再试一次。如果舍弃修改，文件保持磁盘上的样子。"),
        .codeNotSavedSave: ("Save", "存储"),
        .codeNotSavedCancel: ("Cancel", "取消"),
        .codeNotSavedDiscard: ("Discard Changes", "舍弃更改"),
        .menuTextSmaller: ("Make Text Smaller", "缩小文字"),
        .menuRevertCount: ("Revert to Original (%@)", "恢复为原件（%@）"),
        .zoomToSelection: ("Zoom to Selection", "缩放到所选内容"),
        .stepAlign: ("Align", "对齐"),
        .stepDistribute: ("Distribute", "分布"),
        .stepDuplicate: ("Duplicate", "复制"),
        .menuShowAdd: ("Add", "添加"),
        .menuShowLayers: ("Layers", "图层"),
        .menuDesignOnly: ("Design Only", "只看设计"),
        .menuCodeAlongside: ("Code Alongside", "代码并排"),
        .menuCodeOnly: ("Code Only", "只看代码"),
        .menuEverySetting: ("Every Setting", "所有设置"),
        .menuShowInCode: ("Show in Code", "在代码中显示"),
        .menuRainmeterDetails: ("Show Rainmeter Details", "显示 Rainmeter 细节"),
        .menuFullScreen: ("Enter Full Screen", "进入全屏幕"),
        .menuRefresh: ("Refresh", "刷新"),
        .menuPreviewOptions: ("Preview Options…", "预览选项…"),
        .menuMinimize: ("Minimize", "最小化"),
        .menuZoomWindow: ("Zoom", "缩放"),
        .menuLog: ("Log", "日志"),
        .menuAbout: ("About Deskset", "关于 Deskset"),
        .menuSettings: ("Settings…", "设置…"),
        .appMenuHide: ("Hide Deskset", "隐藏 Deskset"),
        .menuQuit: ("Quit Deskset", "退出 Deskset"),
    ]

    static subscript(_ key: Key) -> String { string(key, in: language) }

    /// A size in bytes, as the Mac writes it ("20.4 GB"; nothing is "Zero KB": "0 KB").
    static func bytes(_ value: Double, style: ByteCountFormatter.CountStyle) -> String {
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(max(value.isFinite ? value : 0, 0)))
    }

    /// A time since something, in days and hours ("14 d 5 h" / "14 天 5 小时"), hours and minutes, or minutes.
    static func duration(seconds v: Double) -> String {
        let s = Int(max(v.isFinite ? v : 0, 0))
        let days = s / 86_400, hours = s % 86_400 / 3600, minutes = s % 3600 / 60
        if language == .chinese {
            return days > 0 ? "\(days) 天 \(hours) 小时" : hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
        }
        return days > 0 ? "\(days) d \(hours) h" : hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }

    static func string(_ key: Key, in language: StudioLanguage) -> String {
        guard let entry = table[key] else { return key.rawValue }
        return language == .chinese ? entry.zh : entry.en
    }

    /// The string of `key` with its `%@` / `%d` filled. In Chinese a space goes between Chinese and a Latin letter or
    /// a digit where the sentence meets what is filled in ("只改这个" + "CPU" → "只改这个 CPU"); the filled-in text itself
    /// is left as it is written (a widget's or a file's own name).
    static func format(_ key: Key, _ arguments: CVarArg...) -> String {
        let template = self[key]
        guard language == .chinese else { return String(format: template, arguments: arguments) }
        return spacedFormat(template, arguments)
    }

    /// Marks around each filled-in value (private-use characters, never in the Studio's words).
    private static let open: Character = "\u{E000}", close: Character = "\u{E001}"

    static func spacedFormat(_ template: String, _ arguments: [CVarArg]) -> String {
        // Wrap every specifier (%@, %d, %1$@…; not %%) in the marks.
        var marked = ""
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            guard c == "%" else { marked.append(c); i = template.index(after: i); continue }
            var j = template.index(after: i)
            guard j < template.endIndex else { marked.append(c); break }
            if template[j] == "%" { marked += "%%"; i = template.index(after: j); continue }
            while j < template.endIndex, template[j].isNumber || template[j] == "$" || template[j] == "." ||
                  template[j] == "l" { j = template.index(after: j) }
            guard j < template.endIndex else { marked += template[i...]; break }
            let end = template.index(after: j)
            marked.append(open)
            marked += template[i..<end]
            marked.append(close)
            i = end
        }
        let filled = Array(String(format: marked, arguments: arguments))
        var out = ""
        for (n, c) in filled.enumerated() {
            if c == open {
                let before = out.last, after = filled[(n + 1)...].first { $0 != open && $0 != close }
                if let before, let after, needsSpace(before, after) { out.append(" ") }
            } else if c == close {
                let after = filled[(n + 1)...].first { $0 != open && $0 != close }
                if let before = out.last, let after, needsSpace(before, after) { out.append(" ") }
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Chinese next to a Latin letter or a digit (either way round).
    static func needsSpace(_ a: Character, _ b: Character) -> Bool {
        (isHan(a) && isLatinOrDigit(b)) || (isLatinOrDigit(a) && isHan(b))
    }

    static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    static func isLatinOrDigit(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }
}
