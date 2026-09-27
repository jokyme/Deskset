import Foundation

// Literal checks that need their own parsers (SVG path data, DK4028), the optional layout pass (§4.9.8, DK6101), and
// small rules that apply to one modifier or parameter: `?:` on a modifier (DK4038), `widget.size` in a `.fit`
// widget's layout (DK6010), a quoted name that positions cannot use (DK6008), `supports(…)` (DK8304).

extension Checker {
    // MARK: - Path data

    /// Why SVG path data is invalid (the snippet where it goes wrong, and the reason), or nil.
    static func pathDataProblem(_ data: String) -> (snippet: String, reason: LocalizedText)? {
        let chars = Array(data)
        var i = 0
        var sawCommand = false
        func snippet(_ at: Int) -> String {
            let end = min(chars.count, at + 6)
            return String(chars[max(0, at)..<end]).trimmingCharacters(in: .whitespaces)
        }
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "," || c == "\t" || c == "\n" { i += 1; continue }
            if "MmLlHhVvCcSsQqTtAaZz".contains(c) {
                if !sawCommand && c != "M" && c != "m" {
                    return (snippet(i), LocalizedText("a path starts with M", "路径要以 M 开头"))
                }
                sawCommand = true
                i += 1
                continue
            }
            if c.isNumber || c == "-" || c == "+" || c == "." {
                if !sawCommand { return (snippet(i), LocalizedText("a path starts with M", "路径要以 M 开头")) }
                var j = i + 1
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "e" || chars[j] == "E" { j += 1 }
                i = j
                continue
            }
            return (snippet(i), LocalizedText("“\(c)” is not a path command (M L H V C S Q T A Z)",
                                              "“\(c)” 不是路径命令（M L H V C S Q T A Z）"))
        }
        if !sawCommand { return (data, LocalizedText("the path is empty", "路径是空的")) }
        return nil
    }

    func checkPathData(_ node: PositionedNode, _ val: Val) {
        guard let data = val.stringLiteral, let problem = Checker.pathDataProblem(data) else { return }
        report(.invalidPathData, range(node), ["snippet": .code(problem.snippet), "reason": .text(problem.reason)])
    }

    /// Why a regular expression does not compile, in plain words.
    static func regexReason(_ pattern: String) -> LocalizedText {
        var depth = 0
        for c in pattern { if c == "(" { depth += 1 } else if c == ")" { depth -= 1 } }
        if depth > 0 { return LocalizedText("a `(` has no matching `)`", "有 `(` 没有配对的 `)`") }
        if depth < 0 { return LocalizedText("a `)` has no matching `(`", "有 `)` 没有配对的 `(`") }
        var brackets = 0
        for c in pattern { if c == "[" { brackets += 1 } else if c == "]" { brackets -= 1 } }
        if brackets != 0 { return LocalizedText("a `[` has no matching `]`", "有 `[` 没有配对的 `]`") }
        return LocalizedText("it is not a valid regular expression", "它不是有效的正则表达式")
    }

    // MARK: - Modifier values

    /// DK4038 (info): `.color(c ? a : b)` reads better as `.color(b).color(a, if: c)`.
    func checkTernaryOnModifier(_ spec: ModifierSpec, _ bound: BoundCall, modifier: ModifierAppSyntax) {
        guard spec.acceptsCondition, bound.values.count == 1, let value = bound.values.first,
              value.node.kind == .ternaryExpr else { return }
        let ternary = TernaryExprSyntax(unchecked: value.node)
        let a = text(ternary.then.node), b = text(ternary.otherwise.node), c = text(ternary.condition.node)
        let fixed = ".\(spec.name)(\(b)).\(spec.name)(\(a), if: \(c))"
        report(.ternaryTip, range(value.node), ["name": .code(spec.name), "a": .code(a), "b": .code(b), "cond": .code(c)],
               fixIts: [fix("rewrite", [edit(range(modifier.node), fixed)])])
    }

    /// DK6010: `widget.size` in the layout of a widget whose size follows its content.
    func checkWidgetSizeInLayout(_ spec: ModifierSpec, _ bound: BoundCall) {
        guard preset == "fit", ["width", "height", "size", "position", "padding", "margin"].contains(spec.name) else { return }
        for value in bound.values where value.val.deps.contains(.data("widget.size")) {
            report(.widgetSizeInFitWidget, range(value.node))
        }
    }

    // MARK: - Optional layout pass (§4.9.8)

    /// A simplified fit check: the root's rigid content along its main axis against the preset (DK6101).
    func checkLayoutFit() {
        guard let layout = context.layout, preset != "fit", let root = rootElements.first, rootElements.count == 1,
              let kind = root.kind else { return }
        let presetSize: IdealSize
        guard kind == .column || kind == .row else { return }
        let vertical = kind == .column
        var bigger: String
        switch preset {
        case "small": presetSize = catalog.limits.smallSize; bigger = vertical ? "large" : "medium"
        case "medium": presetSize = catalog.limits.mediumSize; bigger = "large"
        default: presetSize = catalog.limits.largeSize; bigger = "large"
        }
        var total = 0.0
        for child in root.children {
            total += estimatedSize(child, layout: layout, vertical: vertical)
        }
        let spacing = literalArgument(root, "spacing") ?? 8
        total += spacing * Double(max(0, root.children.count - 1))
        total += paddingAmount(root, vertical: vertical)
        let available = vertical ? presetSize.height : presetSize.width
        let over = total - available
        guard over > 0.5 else { return }
        let amount = Int(over.rounded())
        guard let callee = root.node.firstChild(.callee) else { return }
        var fixIts: [FixIt] = []
        if let size = infoFields["size"] {
            fixIts.append(fix("useText", [edit(range(size.value), ".\(bigger)")], ["text": .code("size: .\(bigger)")]))
        }
        report(.contentTooLarge, range(callee), ["amount": .number(amount),
                                                 "direction": hintText(.contentTooLarge, vertical ? "taller" : "wider"),
                                                 "preset": .name("preset:\(preset)"), "bigger": .code(bigger)], fixIts: fixIts)
    }

    private func estimatedSize(_ element: ElementNode, layout: LayoutMeasuring, vertical: Bool) -> Double {
        guard let kind = element.kind else { return 0 }
        if let fixed = literalModifier(element, vertical ? "height" : "width") { return fixed }
        switch kind {
        case .spacer: return 0
        case .text, .label:
            let font = resolvedFont(element)
            var sample = "Text"
            if let argument = element.node.firstChild(.argumentClause).flatMap({ ArgumentClauseSyntax($0)?.arguments.first }) {
                sample = StringLiteralSyntax(argument.value.node)?.literalValue ?? "88"
            }
            let size = layout.textSize(sample, font: font, maxWidth: nil, lines: 1)
            return (vertical ? size.height : size.width) + paddingAmount(element, vertical: vertical)
        case .progress: return vertical ? 6 : 100
        case .divider: return 1
        case .column, .row, .grid, .freeform:
            var total = 0.0
            let inner = kind == .column
            for child in element.children {
                let s = estimatedSize(child, layout: layout, vertical: vertical)
                total = (inner == vertical) ? total + s : max(total, s)
            }
            if inner == vertical { total += (literalArgument(element, "spacing") ?? 8) * Double(max(0, element.children.count - 1)) }
            return total + paddingAmount(element, vertical: vertical)
        default:
            let ideal = element.component?.sizing.idealWhenUnspecified
            return (vertical ? ideal?.height : ideal?.width) ?? 20
        }
    }

    private func resolvedFont(_ element: ElementNode) -> ResolvedFont {
        var font = ResolvedFont()
        for (facet, candidates) in element.facts.facets {
            guard let best = candidates.first(where: { $0.condition == nil }) else { continue }
            let value = best.fixedValue ?? tree.resolve(best.value).map { text($0) } ?? ""
            switch facet.rawValue {
            case "font.size": if let n = Double(value) { font.size = n }
            case "font.weight": font.weight = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            default: break
            }
        }
        return font
    }

    private func literalArgument(_ element: ElementNode, _ label: String) -> Double? {
        guard let clause = element.node.firstChild(.argumentClause).flatMap({ ArgumentClauseSyntax($0) }) else { return nil }
        for argument in clause.arguments where argument.label?.name == label {
            if let n = NumberLiteralSyntax(argument.value.node)?.value { return n }
        }
        return nil
    }

    private func literalModifier(_ element: ElementNode, _ name: String) -> Double? {
        for modifier in modifierApps(of: element.node) where modifier.name.token.text == name {
            if let first = modifier.arguments?.arguments.first, let n = NumberLiteralSyntax(first.value.node)?.value { return n }
        }
        return nil
    }

    private func paddingAmount(_ element: ElementNode, vertical: Bool) -> Double {
        var total = 0.0
        for modifier in modifierApps(of: element.node) where modifier.name.token.text == "padding" {
            for argument in modifier.arguments?.arguments ?? [] {
                guard let n = NumberLiteralSyntax(argument.value.node)?.value else { continue }
                switch argument.label?.name {
                case nil: total += 2 * n
                case "vertical"?: if vertical { total += 2 * n }
                case "horizontal"?: if !vertical { total += 2 * n }
                case "top"?, "bottom"?: if vertical { total += n }
                case "left"?, "right"?: if !vertical { total += n }
                default: break
                }
            }
        }
        return total
    }
}
