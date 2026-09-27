import Foundation

/// The language reference, generated from the catalog in English or Simplified Chinese (Markdown), so the reference
/// never drifts from what the checker knows. The listings read as in the specification (§5.2): `_ name: Type` is
/// positional, `label: Type` labelled, `Type?` may be left out, `= default`, `(a…b)` a range, `whole` a whole number,
/// `…` repeated, `literal` / `literal or option` where the value may come from.
public enum DeskReference {
    public static func markdown(_ catalog: DeskCatalog, language: DiagnosticLanguage) -> String {
        let zh = language == .simplifiedChinese
        func t(_ en: String, _ zhText: String) -> String { zh ? zhText : en }
        func text(_ l: LocalizedText) -> String { cell(l.text(in: language)) }
        func docText(_ d: Doc) -> String { cell(zh ? d.zh : d.en) }
        func example(_ d: Doc) -> String { code(d.example) }
        func rainmeter(_ d: Doc) -> String {
            let spellings = d.rainmeter.map { m -> String in
                "`\(m.qualifiedSpelling)`" + (m.fidelity == .exact ? "" : t(" (approx.)", "（近似）"))
            }
            return spellings.isEmpty ? "—" : cell(spellings.joined(separator: ", "))
        }
        func mac(_ d: Doc) -> String { d.macOnly ? "🍎" : "" }

        var out = "# " + t("Desk language reference", "Desk 语言参考") + "\n\n"
        out += t("Generated from the catalog of Deskset. Since: the Deskset release that introduced the item. 🍎: Mac-specific.",
                 "由 Deskset 的组件目录生成。“版本”是引入该项的 Deskset 版本；🍎 表示 Mac 专有。") + "\n\n"

        // Components.
        out += "## " + t("Components", "组件") + "\n\n"
        for group in ComponentGroup.allCases {
            let items = catalog.components.filter { $0.group == group }
            guard !items.isEmpty else { continue }
            out += "### " + groupTitle(group, language) + "\n\n"
            out += header([t("Component", "组件"), t("Parameters", "参数"), t("Description", "说明"), t("Example", "例子"),
                           "Rainmeter", t("Since", "版本"), "Mac"])
            for x in items {
                out += row(["`\(x.name)`", signatures(x.signatures), docText(x.doc), example(x.doc), rainmeter(x.doc),
                            x.doc.since.description, mac(x.doc)])
            }
            out += "\n"
        }

        // Modifiers.
        out += "## " + t("Modifiers", "修饰符") + "\n\n"
        for group in ModifierGroup.allCases {
            let items = catalog.modifiers.filter { $0.group == group }
            guard !items.isEmpty else { continue }
            out += "### " + groupTitle(group, language) + "\n\n"
            out += header([t("Modifier", "修饰符"), t("Parameters", "参数"), t("Applies to", "用于"), t("Description", "说明"),
                           t("Example", "例子"), "Rainmeter", t("Since", "版本"), "Mac"])
            for m in items {
                let applies = m.appliesTo.kinds.isEmpty ? t("option controls", "选项控件")
                    : m.appliesTo == .all ? t("all", "全部") : m.appliesTo.kinds.map(\.rawValue).joined(separator: ", ")
                out += row(["`.\(m.name)`", signatures(m.signatures), cell(applies), docText(m.doc), example(m.doc),
                            rainmeter(m.doc), m.doc.since.description, mac(m.doc)])
            }
            out += "\n"
        }

        // Data, actions of namespaces.
        out += "## " + t("Data", "数据") + "\n\n"
        out += header([t("Name", "名字"), t("Type", "类型"), t("Description", "说明"), t("Example", "例子"), "Rainmeter",
                       t("Since", "版本"), "Mac"])
        for ns in catalog.namespaces {
            if let value = ns.value {
                out += row(["`\(ns.name)`", code(value.type.description), docText(value.doc), example(value.doc),
                            rainmeter(value.doc), value.doc.since.description, mac(value.doc)])
            }
            for m in ns.members {
                let name = "`\(ns.name).\(m.name)\(parentheses(m))`"
                let type = m.kind == .action ? t("action", "动作") : code(m.type.description)
                out += row([name, type, docText(m.doc), example(m.doc), rainmeter(m.doc), m.doc.since.description, mac(m.doc)])
            }
        }
        out += "\n"

        // Functions and actions.
        out += "## " + t("Functions and actions", "函数和动作") + "\n\n"
        out += header([t("Name", "名字"), t("Parameters", "参数"), t("Description", "说明"), t("Example", "例子"), "Rainmeter",
                       t("Since", "版本"), "Mac"])
        for f in catalog.functions {
            out += row(["`\(f.name)`", signatures(f.signatures), docText(f.doc), example(f.doc), rainmeter(f.doc),
                        f.doc.since.description, mac(f.doc)])
        }
        out += "\n"

        // Members of values.
        out += "## " + t("Members of values", "值的成员") + "\n\n"
        out += header([t("On", "类型"), t("Member", "成员"), t("Description", "说明"), t("Example", "例子")])
        for tm in catalog.typeMembers {
            for m in tm.members {
                out += row([tm.type, "`.\(m.name)\(parentheses(m))`", docText(m.doc), example(m.doc)])
            }
        }
        out += "\n"

        // Records.
        out += "## " + t("Records", "记录") + "\n\n"
        for r in catalog.records {
            out += "### \(r.id)\n\n" + (zh ? r.doc.zh : r.doc.en) + "\n\n"
            out += header([t("Field", "字段"), t("Type", "类型"), t("Description", "说明")])
            for f in r.fields {
                out += row(["`\(f.name)`" + (r.identityField == f.name ? " 🔑" : ""), code(f.type.description), docText(f.doc)])
            }
            out += "\n"
        }

        // Enums and named values.
        out += "## " + t("Choices", "内置选项") + "\n\n"
        out += header([t("Type", "类型"), t("Choices", "选项"), t("Description", "说明")])
        for e in catalog.enums {
            let cases = e.cases.map { "`.\($0.name)`" }.joined(separator: " ")
            out += row([e.id, cases, docText(e.doc)])
        }
        for type in ["Color", "Paint"] {
            let values = catalog.namedValues.filter { $0.type == type }.map { "`.\($0.name)`" }.joined(separator: " ")
            out += row([type, values, type == "Color" ? t("Colors that adapt to light and dark", "随浅色和深色变化的颜色")
                                                      : t("Colors, and glass for backgrounds", "颜色，以及用于背景的玻璃")])
        }
        out += "\n"

        // Options.
        out += "## " + t("Option controls", "选项控件") + "\n\n"
        out += header([t("Control", "控件"), t("Parameters", "参数"), t("Description", "说明"), t("Example", "例子"), "Mac"])
        for x in catalog.controls {
            out += row(["`\(x.name)`", signatures(x.signatures), docText(x.doc), example(x.doc), mac(x.doc)])
        }
        out += "\n## " + t("`info` and `package` fields", "`info` 和 `package` 字段") + "\n\n"
        out += header([t("Field", "字段"), t("In", "用于"), t("Type", "类型"), t("Description", "说明"), t("Example", "例子")])
        for f in catalog.infoFields + catalog.packageFields.filter({ !$0.inInfo }) {
            let places = [f.inInfo ? "info" : nil, f.inPackage ? "package" : nil].compactMap { $0 }.joined(separator: ", ")
            out += row(["`\(f.name)`", places, code(f.type.description), docText(f.doc), example(f.doc)])
        }

        // Text, units, permissions, features.
        out += "\n## " + t("Format options", "格式选项") + "\n\n"
        out += header([t("Option", "选项"), t("Applies to", "用于"), t("Values", "取值"), t("Description", "说明"), t("Example", "例子")])
        for f in catalog.formatOptions {
            out += row(["`\(f.label):`", cell(f.appliesTo.map(\.description).joined(separator: ", ")), code(f.type.description),
                        docText(f.doc), example(f.doc)])
        }
        out += "\n## " + t("Units", "单位") + "\n\n"
        out += header([t("Unit", "单位"), t("Measures", "量")])
        for (dimension, units) in Dictionary(grouping: catalog.units, by: \.dimension).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let name = catalog.displayName("dimension:\(dimension.rawValue)")?.name.text(in: language) ?? dimension.rawValue
            out += row([units.map { "`\($0.spelling)`" }.joined(separator: " "), cell(name)])
        }
        out += "\n## " + t("Permissions", "权限") + "\n\n"
        out += header([t("Permission", "权限"), t("This widget …", "这个组件要……"), t("Asked by macOS as", "系统提示")])
        for p in catalog.permissions {
            out += row(["`.\(p.id)`", text(p.needsPhrase), cell(p.systemPrompt ?? "—")])
        }
        out += "\n## " + t("Features", "能力") + "\n\n"
        out += header([t("Feature", "能力"), t("True when", "何时为真"), t("Otherwise", "否则")])
        for f in catalog.features { out += row(["`.\(f.id)`", cell(f.availability), text(f.fallback)]) }

        // Diagnostics.
        out += "\n## " + t("Messages", "报错") + "\n\n"
        out += header(["ID", t("Severity", "级别"), t("Message", "信息")])
        for d in catalog.diagnostics {
            let severity: String
            switch d.severity {
            case .error: severity = t("error", "错误")
            case .warning: severity = t("warning", "警告")
            case .info: severity = t("tip", "提示")
            }
            out += row([d.id.rawValue, severity, cell(d.template.text(in: language))])
        }
        return out
    }

    // MARK: Pieces

    static func groupTitle(_ group: ComponentGroup, _ language: DiagnosticLanguage) -> String {
        let titles: [ComponentGroup: LocalizedText] = [
            .containers: LocalizedText("Containers", "容器"), .content: LocalizedText("Content", "内容"),
            .shapes: LocalizedText("Shapes", "形状"), .controls: LocalizedText("Controls", "控件"),
            .menuEntries: LocalizedText("Menu entries", "菜单项"),
        ]
        return titles[group]!.text(in: language)
    }

    static func groupTitle(_ group: ModifierGroup, _ language: DiagnosticLanguage) -> String {
        let titles: [ModifierGroup: LocalizedText] = [
            .sizeAndPosition: LocalizedText("Size and position", "大小和位置"), .appearance: LocalizedText("Appearance", "外观"),
            .shapesAndMeters: LocalizedText("Shapes and meters", "形状和进度"), .text: LocalizedText("Text", "文字"),
            .picturesAndIcons: LocalizedText("Pictures and icons", "图片和图标"), .transforms: LocalizedText("Transforms", "变换"),
            .statesAndAnimation: LocalizedText("States and animation", "状态和动画"),
            .interaction: LocalizedText("Interaction", "交互"), .timing: LocalizedText("Timing", "时机"),
            .reuse: LocalizedText("Reuse, accessibility, compatibility, options", "复用、无障碍、兼容和选项"),
        ]
        return titles[group]!.text(in: language)
    }

    /// Nothing for a field, `()` for a call without values, `(…)` for one with values.
    static func parentheses(_ m: MemberSpec) -> String {
        if m.kind == .field { return "" }
        return m.signatures.allSatisfy { $0.params.isEmpty } ? "()" : "(…)"
    }

    /// `_ value: Number or Fraction, total: Number?` — signatures separated by `·`.
    static func signatures(_ signatures: [Signature]) -> String {
        let written = signatures.map { s -> String in
            s.params.isEmpty ? "—" : s.params.map(parameter).joined(separator: ", ")
        }
        return cell(written.map { "`\($0)`" }.joined(separator: " · "))
    }

    /// How a parameter reads in the listings and in hover help: `columns: Number (1…64) whole`, `_ all: Length?`.
    public static func parameter(_ p: ParamSpec) -> String {
        var s = (p.label ?? "_ \(p.name)") + ": " + p.type.description
        if !p.required && p.defaultValue == nil { s += "?" }
        switch p.defaultValue {
        case .source(let text)?: s += " = \(text)"
        case .parameter(let other)?: s += " = \(other)"
        case .system?, nil: break
        }
        if let range = p.range { s += " (\(number(range.lowerBound))…\(number(range.upperBound)))" }
        if p.wholeNumber { s += " whole" }
        if p.variadic { s += "…" }
        switch p.source {
        case .literal: s += " literal"
        case .literalOrOption: s += " literal or option"
        case .any: break
        }
        return s
    }

    static func number(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x)
    }

    /// Desk text in a table cell: in backquotes, with `|` escaped and lines joined.
    static func code(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: "; ")
        let fence = oneLine.contains("`") ? "``" : "`"
        return cell(fence + (fence == "``" ? " \(oneLine) " : oneLine) + fence)
    }

    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    static func header(_ titles: [String]) -> String {
        row(titles) + "|" + titles.map { _ in "---" }.joined(separator: "|") + "|\n"
    }

    static func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |\n" }
}
