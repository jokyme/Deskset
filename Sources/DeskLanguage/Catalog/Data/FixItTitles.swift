import Foundation

// Button titles of fix-its and messages of notes. `{text}` is Desk text shown as written.

extension CatalogData {
    static let fixItTitles: [FixItTitleSpec] = [
        title("fix", "Fix", "改正"),
        title("fixAll", "Fix all", "全部改正"),
        title("replace", "Replace", "替换"),
        title("replaceWith", "Replace with `{text}`", "换成 `{text}`"),
        title("replaceWithSpace", "Replace with a space", "换成普通空格"),
        title("replaceWithHost", "Keep only the host", "只保留域名"),
        title("replaceWithSimilarFile", "Use the similar file", "换成相近的文件"),
        title("remove", "Remove", "删除"),
        title("removeText", "Remove `{text}`", "删除 `{text}`"),
        title("removeOne", "Remove one", "删掉其中一个"),
        title("removeThisOne", "Remove this one", "删除这一个"),
        title("removeBlock", "Remove the block", "删除这对花括号"),
        title("removeDot", "Remove the dot", "去掉点"),
        title("removeLabels", "Remove the labels", "去掉名字"),
        title("removeQuotes", "Remove the quotes", "去掉引号"),
        title("removeSpace", "Remove the space", "去掉空格"),
        title("removeExtra", "Remove the extra value", "删除多出来的值"),
        title("removeClosureParameter", "Remove `{name} in` and use `{value}`", "去掉 `{name} in`，改用 `{value}`"),
        title("insert", "Insert `{text}`", "插入 `{text}`"),
        title("insertName", "Insert the name `{text}`", "加上名字 `{text}`"),
        title("insertParentheses", "Insert the parentheses", "加上括号"),
        title("add", "Add", "添加"),
        title("addQuotes", "Add quotes", "加上引号"),
        title("addBinding", "Add the value it changes", "加上它要改的值"),
        title("append", "Append `{text}`", "在后面加上 `{text}`"),
        title("changeTo", "Change to `{text}`", "改成 `{text}`"),
        title("clamp", "Keep it in range", "限制在范围内"),
        title("round", "Round", "取整"),
        title("swap", "Swap", "对调"),
        title("reorder", "Reorder", "调整顺序"),
        title("rename", "Rename", "重命名"),
        title("renameTo", "Rename to `{text}`", "重命名为 `{text}`"),
        title("renameEverywhere", "Rename everywhere", "全部重命名"),
        title("renameEverywhereTo", "Rename everywhere to `{text}`", "全部重命名为 `{text}`"),
        title("renameThisOne", "Rename this one", "重命名这一个"),
        title("renameThisOneEverywhere", "Rename this one everywhere", "把这一个全部重命名"),
        title("rewrite", "Rewrite", "改写"),
        title("didYouMean", "Change to `{text}`", "改成 `{text}`"),
        title("convert", "Change to `{text}`", "改成 `{text}`"),
        title("createStyle", "Create the style", "新建这个样式"),
        title("jumpToLine", "Jump to line {line}", "跳到第 {line} 行"),
        title("joinLines", "Join the lines", "合并成一行"),
        title("newLine", "Put on its own line", "分成两行"),
        title("moveBelow", "Move below `{text}`", "挪到 `{text}` 下面"),
        title("moveInto", "Move into `{text}`", "挪进 `{text}`"),
        title("moveIntoEachBranch", "Move into each branch", "挪进每个分支"),
        title("moveOntoElement", "Move onto the element inside", "挪到里面的元素上"),
        title("moveOutOfWidget", "Move out of `widget`", "挪到 `widget` 外面"),
        title("moveConditionToStyle", "Move the condition to `.style(…, if: …)`", "把条件挪到 `.style(…, if: …)`"),
        title("moveNameToInfo", "Move the name to `info`", "把名字挪到 `info` 里"),
        title("moveToTop", "Move to the top of `widget`", "挪到 `widget` 的最上面"),
        title("wrapIn", "Wrap in `{text}`", "用 `{text}` 包起来"),
        title("useFirstChoice", "Use the first choice", "改用第一个选项"),
        title("useBraces", "Use braces", "改用花括号"),
        title("useText", "Use `{text}`", "改用 `{text}`"),
        title("showBackslash", "Show the backslash", "显示反斜杠"),
        title("writeAsRaw", "Write as `#\"…\"#`", "写成 `#\"…\"#`"),
        title("writeUnit", "Write `{text}`", "写成 `{text}`"),
        title("qualifyChoice", "Write `{text}`", "写成 `{text}`"),
        title("declareWith", "Declare with `{text}`", "用 `{text}` 声明"),
        title("closeQuotes", "End the quotes around the value", "在值的两边断开引号"),
    ]

    static let notes: [NoteSpec] = [
        note("declaredHere", "Declared here.", "在这里声明。"),
        note("packageDeclaration", "The package's declaration.", "包里的声明。"),
        note("otherCopy", "The other copy.", "另一处。"),
        note("usedHere", "Used here.", "在这里用到。"),
        note("openedHere", "Opened here.", "在这里开始。"),
        note("previousElement", "The element before it.", "它前面的元素。"),
        note("inWidget", "Found while checking {name}.", "在检查 {name} 时发现。"),
        note("otherFile", "The other file.", "另一个文件。"),
        note("needsVersion", "This widget needs Deskset {version}.", "这个组件需要 Deskset {version}。"),
    ]

    private static func title(_ key: String, _ en: String, _ zh: String) -> FixItTitleSpec {
        FixItTitleSpec(key: key, title: LocalizedText(en, zh))
    }

    private static func note(_ key: String, _ en: String, _ zh: String) -> NoteSpec {
        NoteSpec(key: key, text: LocalizedText(en, zh))
    }
}
