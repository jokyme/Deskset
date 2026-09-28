import Foundation

// DK86xx: problems only a whole widget folder shows (the files next to each other, their names, links, how many and
// how large they are, pictures no widget uses). The package loader and validator report them; a single file never
// does.

extension CatalogData {
    /// DK86xx — the widget folder.
    static let packageDiagnostics: [DiagnosticSpec] = [
        DiagnosticSpec(
            id: .packageWithoutWidget, severity: .error,
            trigger: #"a folder with only `package.desk`"#,
            template: LocalizedText(
                #"This folder has no widget. Add a `.desk` file with `widget { … }` next to `package.desk`."#,
                #"这个文件夹里没有组件。请在 `package.desk` 旁边加一个带 `widget { … }` 的 `.desk` 文件。"#),
            placeholders: [:]
        ),
        DiagnosticSpec(
            id: .fileNameClash, severity: .error,
            trigger: #"`Clock.desk` and `clock.desk` in one folder"#,
            template: LocalizedText(
                #"`{path}` and `{other}` differ only in {difference}, so a Mac sees one file. Rename one of them."#,
                #"`{path}` 和 `{other}` 只差在{difference}，Mac 会把它们当成同一个文件。请改掉其中一个的名字。"#),
            placeholders: ["path": .code, "other": .code, "difference": .text],
            hints: [
                HintSpec(key: "case", placeholder: "difference",
                         text: LocalizedText(#"upper and lower case"#, #"大小写"#)),
                HintSpec(key: "normalization", placeholder: "difference",
                         text: LocalizedText(#"how accented letters are stored"#, #"带重音字母的存储方式"#)),
            ]
        ),
        DiagnosticSpec(
            id: .duplicateWidgetName, severity: .warning,
            trigger: #"two widgets named "Clock" in one folder"#,
            template: LocalizedText(
                #"Another widget in this folder is also called "{name}"; people can't tell them apart in the library."#,
                #"这个文件夹里另一个组件也叫“{name}”，在小组件库里分不出来。"#),
            placeholders: ["name": .plain]
        ),
        DiagnosticSpec(
            id: .packageRequiresTooOld, severity: .warning,
            trigger: #"`package { requires: "1.0" }` while a widget needs 1.2"#,
            template: LocalizedText(
                #"The package says it runs on Deskset {version}, but {widget} needs Deskset {needed}."#,
                #"包里写的是 Deskset {version} 就能运行，但 {widget} 需要 Deskset {needed}。"#),
            placeholders: ["version": .plain, "widget": .plain, "needed": .plain],
            fixIts: [
                FixItSpec("replaceWith"),
            ]
        ),
        DiagnosticSpec(
            id: .widgetInSubfolder, severity: .warning,
            trigger: #"`Extras/Clock.desk`"#,
            template: LocalizedText(
                #"Deskset loads only the `.desk` files at the top of the folder, so `{path}` is left out. Move it next to the other widgets."#,
                #"Deskset 只载入文件夹最上层的 `.desk` 文件，所以不会载入 `{path}`。请把它挪到和其他组件同一层。"#),
            placeholders: ["path": .code]
        ),
        DiagnosticSpec(
            id: .fileLink, severity: .error,
            trigger: #"`bg.png` is a link to a picture elsewhere"#,
            template: LocalizedText(
                #"`{path}` is a link{hint}. Deskset doesn't follow links; put the file itself in the folder."#,
                #"`{path}` 是一个链接{hint}。Deskset 不会跟随链接，请把文件本身放进文件夹。"#),
            placeholders: ["path": .code, "hint": .text],
            hints: [
                HintSpec(key: "outside", text: LocalizedText(#" to a place outside the folder"#, #"，指向文件夹外面"#)),
                HintSpec(key: "inside", text: LocalizedText(#" to another file in the folder"#, #"，指向文件夹里的另一个文件"#)),
            ]
        ),
        DiagnosticSpec(
            id: .tooManyFiles, severity: .error,
            trigger: #"2,001 files"#,
            template: LocalizedText(
                #"This folder has more than {limit} files; Deskset reads at most {limit}."#,
                #"这个文件夹里的文件超过了 {limit} 个，Deskset 最多读取 {limit} 个。"#),
            placeholders: ["limit": .number]
        ),
        DiagnosticSpec(
            id: .folderTooLarge, severity: .error,
            trigger: #"files adding up to 101 MiB"#,
            template: LocalizedText(
                #"The files in this folder add up to more than {limit} MiB."#,
                #"这个文件夹里的文件加起来超过了 {limit} MiB。"#),
            placeholders: ["limit": .number]
        ),
        DiagnosticSpec(
            id: .unusedAsset, severity: .info,
            trigger: #"`old.png` that no widget shows"#,
            template: LocalizedText(
                #"No widget in this folder shows `{path}`; it is still shared with the others."#,
                #"这个文件夹里没有组件用到 `{path}`，分享时它仍会被一起打包。"#),
            placeholders: ["path": .code]
        ),
    ]
}
