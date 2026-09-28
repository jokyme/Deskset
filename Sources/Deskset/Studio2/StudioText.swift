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
        // The popover the name opens.
        case runningTitle = "running.title"
        case runningFile = "running.file"
        case runningNothing = "running.nothing"
        case runningBuiltIn = "running.builtIn"
        case runningRainmeter = "running.rainmeter"
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
        .runningTitle: ("Running on your desktop", "桌面上运行的"),
        .runningFile: ("%@", "%@"),
        .runningNothing: ("Nothing: the widget is not on your desktop right now.", "没有：这个小组件现在不在桌面上。"),
        .runningBuiltIn: ("A widget that comes with Deskset.", "Deskset 自带的小组件。"),
        .runningRainmeter: ("The skin’s own file: changes are written into it.", "皮肤自己的文件：改动写进这个文件。"),
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
        .backdropClose: ("Close to your wallpaper", "接近你的壁纸"),
        .backdropSimilarTip: ("macOS does not say which picture shows now; this is one of them.",
                              "macOS 不告诉我们现在显示的是哪一张，这是其中一张。"),
        .backdropCloseTip: ("Your wallpaper is in a place macOS asks about before it can be read, so a sample close to it stands in.",
                            "你的壁纸在需要 macOS 授权才能读取的地方，所以这里用一张接近的样例代替。"),
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
        .lookShared: ("The look is shared by all %d %@ widgets", "全部 %d 个 %@ 小组件共用这个外观"),
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
    ]

    static subscript(_ key: Key) -> String { string(key, in: language) }

    static func string(_ key: Key, in language: StudioLanguage) -> String {
        guard let entry = table[key] else { return key.rawValue }
        return language == .chinese ? entry.zh : entry.en
    }

    /// The string of `key` with its `%@` / `%d` filled.
    static func format(_ key: Key, _ arguments: CVarArg...) -> String {
        String(format: self[key], arguments: arguments)
    }
}
