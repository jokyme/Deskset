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
