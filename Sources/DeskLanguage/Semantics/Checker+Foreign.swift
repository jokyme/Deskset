import Foundation

// Foreign syntax (§6.4): SwiftUI, Swift, React, Flutter, HTML, CSS, Rainmeter and older Desk drafts. The parser
// recognises foreign lines without the catalog; the checker fills in the Desk spelling from the catalog's foreign
// table (and its Rainmeter mappings) and adds the exact fix-its. Names, modifiers, members, implicit members and
// labels are looked up in the same table before did-you-mean.

extension Checker {
    // MARK: - Parser diagnostics

    /// Completes the parser's foreign diagnostics with their `{desk}` text and fix-its (the parser has no catalog).
    func enrichParserDiagnostics() {
        for d in tree.diagnostics {
            var replaced: Diagnostic?
            switch d.id {
            case .rainmeterOption:
                replaced = enrichIniOption(d)
            case .rainmeterSection:
                var copy = d
                if copy.arguments["desk"] == nil { copy.arguments["desk"] = .code("Text(\"…\")") }
                replaced = copy
            case .rainmeterBang:
                replaced = enrichBang(d)
            case .rainmeterVariable:
                var copy = d
                if case .code(let raw)? = d.arguments["name"] {
                    let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                    let lower = name.prefix(1).lowercased() + name.dropFirst()
                    copy.arguments["name"] = .code(name)
                    copy.arguments["desk"] = .code("options.\(lower)")
                    options[lower]?.used = true
                    options[name]?.used = true
                    if options[lower] != nil || options[name] != nil, copy.fixIts.isEmpty {
                        copy.fixIts = [fix("replaceWith", [edit(d.range, "options.\(options[lower] != nil ? lower : name)")],
                                           ["text": .code("options.\(lower)")])]
                    }
                } else if copy.arguments["desk"] == nil {
                    copy.arguments["desk"] = .code("options.x")
                }
                replaced = copy
            case .htmlTag:
                var copy = d
                if copy.arguments["desk"] == nil {
                    let line = lineText(at: d.range.lowerBound)
                    copy.arguments["desk"] = .text(htmlDesk(for: line))
                }
                replaced = copy
            case .cssDeclaration:
                replaced = enrichCss(d)
            case .cssSelector:
                var copy = d
                if case .code(let n)? = d.arguments["name"] {
                    copy.arguments["name"] = .code(DidYouMean.lowerCamel(from: n))
                }
                replaced = copy
            case .swiftStructure, .swiftDeclaration, .functionSyntax, .swiftPropertyWrapper:
                var copy = d
                if copy.arguments["desk"] == nil {
                    if case .code(let keyword)? = d.arguments["keyword"], let row = index.foreignRows(keyword).first {
                        copy.arguments["desk"] = .code(row.deskText.isEmpty ? keyword : row.deskText)
                    } else if case .code(let name)? = d.arguments["name"], let row = index.foreignRows(name).first {
                        copy.arguments["desk"] = .code(row.deskText)
                    } else {
                        copy.arguments["desk"] = .code("widget { … }")
                    }
                }
                replaced = copy
            case .directionMark, .unusualSpace, .invisibleCharacter:
                // `{name}` is a phrase: keep the character's name as written.
                replaced = nil
            default:
                replaced = nil
            }
            if let replaced, replaced != d { replacedParserDiagnostics[diagnosticKey(d)] = replaced }
        }
    }

    func lineText(at offset: Int) -> String {
        let bytes = Array(tree.text.utf8)
        var start = min(offset, bytes.count), end = min(offset, bytes.count)
        while start > 0, bytes[start - 1] != 0x0A, bytes[start - 1] != 0x0D { start -= 1 }
        while end < bytes.count, bytes[end] != 0x0A, bytes[end] != 0x0D { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    func lineRange(at offset: Int) -> Range<Int> {
        let bytes = Array(tree.text.utf8)
        var start = min(offset, bytes.count), end = min(offset, bytes.count)
        while start > 0, bytes[start - 1] != 0x0A, bytes[start - 1] != 0x0D { start -= 1 }
        while end < bytes.count, bytes[end] != 0x0A, bytes[end] != 0x0D { end += 1 }
        var s = start
        while s < end, bytes[s] == 0x20 || bytes[s] == 0x09 { s += 1 }
        return s..<end
    }

    /// `FontColor=255,255,255` → `.color("#FFFFFF")`; the keys Desk does not need become DK9306.
    func enrichIniOption(_ d: Diagnostic) -> Diagnostic? {
        guard case .code(let key)? = d.arguments["name"] else { return nil }
        var value = ""
        if case .code(let v)? = d.arguments["value"] { value = v }
        var copy = d
        let rows = index.foreignRows(key).filter { if case .iniKey = $0.pattern { return true }; return false }
        let row = rows.first { $0.context == .any } ?? rows.first
        guard let row else {
            // No row: the catalog's Rainmeter mappings, else "no direct form".
            let mapping = catalogDeskName(forRainmeterKey: key)
            copy.arguments["desk"] = .code(mapping ?? "no direct form; see the language reference")
            return copy
        }
        if row.diagnostic == .rainmeterNotNeeded {
            let why: LocalizedText
            switch key {
            case "DynamicVariables": why = LocalizedText("values update by themselves", "值会自动更新")
            case "UpdateDivider": why = LocalizedText("each kind of data has its own pace", "每种数据有自己的刷新节奏")
            case "AntiAlias": why = LocalizedText("everything is drawn smoothly", "所有内容都会平滑绘制")
            default:
                let ms = Int(value.trimmingCharacters(in: .whitespaces)) ?? 1000
                why = LocalizedText("write `info { refresh: \(ms)ms }` to change how often data updates",
                                    "要改数据刷新的频率，写 `info { refresh: \(ms)ms }`")
            }
            let lineR = lineRange(at: d.range.lowerBound)
            return Diagnostic(id: .rainmeterNotNeeded, severity: .error, file: d.file, range: d.range,
                              arguments: ["option": .code(key), "why": .text(why)],
                              fixIts: [fix("remove", [edit(lineR, "")])])
        }
        var desk = row.deskText
        desk = desk.replacingOccurrences(of: "{value}", with: value)
        if desk.contains("{hex}") {
            guard let hex = Checker.rainmeterHex(value) else {
                copy.arguments["desk"] = .code(row.deskText.replacingOccurrences(of: "{hex}", with: "#…"))
                return copy
            }
            desk = desk.replacingOccurrences(of: "{hex}", with: hex)
        }
        if key == "FontSize", let n = Double(value.trimmingCharacters(in: .whitespaces)) {
            let points = (n * 4 / 3 * 2).rounded() / 2
            desk = ".font(\(Checker.numberText(points)))"
        }
        if key == "StringAlign" {
            let v = value.lowercased()
            desk = v.contains("right") ? ".align(.right)" : v.contains("center") ? ".align(.center)" : ".align(.left)"
        }
        copy.arguments["desk"] = .code(desk)
        if row.exact && copy.fixIts.isEmpty {
            copy.fixIts = [fix("replace", [edit(lineRange(at: d.range.lowerBound), desk)])]
        }
        return copy
    }

    /// `255,107,0` → `#FF6B00`; `255,107,0,128` → `#FF6B0080`.
    static func rainmeterHex(_ value: String) -> String? {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 3 || parts.count == 4 {
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == parts.count, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return "#" + numbers.map { String(format: "%02X", $0) }.joined()
        }
        let hex = value.trimmingCharacters(in: .whitespaces)
        if [6, 8].contains(hex.count), hex.allSatisfy({ $0.isHexDigit }) { return "#" + hex.uppercased() }
        return nil
    }

    /// The Desk name the catalog maps a Rainmeter key to (`FontColor` → `.color`).
    func catalogDeskName(forRainmeterKey key: String) -> String? {
        for m in catalog.modifiers where m.doc.rainmeter.contains(where: { $0.key == key }) { return "." + m.name + "(…)" }
        for c in catalog.components where c.doc.rainmeter.contains(where: { $0.key == key }) { return c.name + "(…)" }
        for f in catalog.infoFields where f.doc.rainmeter.contains(where: { $0.key == key }) { return "info { \(f.name): … }" }
        return nil
    }

    func enrichBang(_ d: Diagnostic) -> Diagnostic? {
        guard case .code(let bang)? = d.arguments["bang"] else { return nil }
        var copy = d
        let line = lineText(at: d.range.lowerBound).trimmingCharacters(in: .whitespaces)
        let rows = index.foreignRows("!" + bang)
        guard let row = rows.first else {
            copy.arguments["desk"] = .code(catalogDeskName(forBang: "!" + bang) ?? "no direct form; see the language reference")
            return copy
        }
        // Arguments of the bang: `[!SetVariable Page 1]`.
        var inner = line
        if let open = inner.firstIndex(of: "["), let close = inner.lastIndex(of: "]"), open < close {
            inner = String(inner[inner.index(after: open)..<close])
        }
        let words = inner.split(separator: " ").map(String.init).dropFirst()
        var desk = row.deskText
        if let first = words.first {
            let lower = first.prefix(1).lowercased() + first.dropFirst()
            desk = desk.replacingOccurrences(of: "{name}", with: lower)
            desk = desk.replacingOccurrences(of: "{0}", with: first.hasPrefix("\"") ? first : "\"\(words.joined(separator: " "))\"")
        }
        if words.count > 1 { desk = desk.replacingOccurrences(of: "{value}", with: words.dropFirst().joined(separator: " ")) }
        copy.arguments["desk"] = .code(desk)
        if row.exact && !desk.contains("{") && copy.fixIts.isEmpty {
            copy.fixIts = [fix("replace", [edit(d.range, desk)])]
        }
        return copy
    }

    func catalogDeskName(forBang bang: String) -> String? {
        for f in catalog.functions where f.doc.rainmeter.contains(where: { $0.key == bang }) { return f.name + "(…)" }
        return nil
    }

    func htmlDesk(for line: String) -> LocalizedText {
        for row in catalog.foreign where row.diagnostic == .htmlTag {
            if case .line(let regex) = row.pattern, line.range(of: regex, options: .regularExpression) != nil {
                let parts = row.deskText.components(separatedBy: " or ")
                return LocalizedText(parts.map { "`\($0)`" }.joined(separator: " or "), parts.map { "`\($0)`" }.joined(separator: " 或 "))
            }
        }
        return LocalizedText("`Column { … }` or `Row { … }`", "`Column { … }` 或 `Row { … }`")
    }

    func enrichCss(_ d: Diagnostic) -> Diagnostic? {
        var copy = d
        let line = lineText(at: d.range.lowerBound)
        for row in catalog.foreign where row.diagnostic == .cssDeclaration {
            guard case .line(let regex) = row.pattern,
                  let regexObject = try? NSRegularExpression(pattern: regex) else { continue }
            let ns = line as NSString
            guard let match = regexObject.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            var desk = row.deskText
            if match.numberOfRanges > 1 {
                // The first capture that holds a value.
                var captured: String?
                for i in 1..<match.numberOfRanges where match.range(at: i).location != NSNotFound {
                    let s = ns.substring(with: match.range(at: i)).trimmingCharacters(in: .whitespaces)
                    if s != "-color" && s != "px" && s != "pt" { captured = s; break }
                }
                if let c = captured {
                    var value = c
                    if desk.hasPrefix(".color(") || desk.hasPrefix(".background(") {
                        value = value.hasPrefix("#") ? "\"\(value.uppercased())\"" : "." + value
                    }
                    desk = desk.replacingOccurrences(of: "{0}", with: value)
                }
            }
            copy.arguments["desk"] = .code(desk)
            if row.exact && !desk.contains("{") && copy.fixIts.isEmpty {
                copy.fixIts = [fix("replace", [edit(lineRange(at: d.range.lowerBound), desk)])]
            }
            return copy
        }
        copy.arguments["desk"] = .code("Column { … } or Row { … }")
        return copy
    }

    // MARK: - Names

    func foreignRows(forName name: String) -> [ForeignSpec] {
        index.foreignRows(name).filter {
            switch $0.pattern {
            case .name, .keyword: return true
            default: return false
            }
        }
    }

    func isForeignComponent(_ name: String) -> Bool { !foreignRows(forName: name).isEmpty }

    /// A foreign name (`VStack`, `Layers`, `Bar`, `self`, `nil`).
    func reportForeignName(_ row: ForeignSpec, at r: Range<Int>, name: String, call: CallStmtSyntax?,
                           callArguments: ArgumentClauseSyntax? = nil) {
        var desk = row.deskText
        if desk.contains("{0}") {
            let first = call?.arguments?.arguments.first.map { text($0.value.node) }
                ?? callArguments?.arguments.first.map { text($0.value.node) } ?? "…"
            desk = desk.replacingOccurrences(of: "{0}", with: first)
        }
        let fixIts: [FixIt] = row.exact && !desk.contains("…") && !desk.contains(" ") ? [fix("replace", [edit(r, desk)])] : []
        switch row.diagnostic {
        case .swiftUIComponent:
            report(.swiftUIComponent, r, ["desk": .code(desk)], fixIts: fixIts)
        case .olderDeskName:
            report(.olderDeskName, r, ["new": .code(desk)], fixIts: fixIts)
        case .otherFrameworkName:
            report(.otherFrameworkName, r, ["name": .code(name), "family": .text(familyName(row.family)), "desk": .code(desk)],
                   fixIts: fixIts)
        case .unknownComponent:
            report(.unknownComponent, r, ["name": .code(name), "suggestion": .code(desk)], fixIts: fixIts)
        case .swiftName:
            report(.swiftName, r, ["desk": .code(desk), "swift": .code(name)], fixIts: fixIts)
        case .swiftStructure:
            report(.swiftStructure, r)
        default:
            report(row.diagnostic, r, ["desk": .code(desk), "name": .code(name)], fixIts: fixIts)
        }
    }

    func familyName(_ family: ForeignSpec.Family) -> LocalizedText {
        switch family {
        case .swiftUI: return LocalizedText("SwiftUI", "SwiftUI")
        case .swift: return LocalizedText("Swift", "Swift")
        case .javaScript: return LocalizedText("JavaScript", "JavaScript")
        case .reactNative: return LocalizedText("React Native", "React Native")
        case .flutter: return LocalizedText("Flutter", "Flutter")
        case .html: return LocalizedText("HTML", "HTML")
        case .css: return LocalizedText("CSS", "CSS")
        case .rainmeter: return LocalizedText("Rainmeter", "Rainmeter")
        case .olderDesk: return LocalizedText("an older Desk", "旧版 Desk")
        case .other: return LocalizedText("another tool", "别的工具")
        }
    }

    /// A component-position call with a foreign name: `VStack { }`, `Image(systemName: "x")`, `Bar(…)`.
    func reportForeignComponent(_ call: CallStmtSyntax) -> Bool {
        let path = call.callee.path
        guard path.count == 1 else { return false }
        let name = path[0]
        let r = range(call.callee.node)
        let labels = call.arguments?.arguments.compactMap { $0.label?.name } ?? []
        // Calls with a telling label: `Image(systemName:)`, `ZStack(alignment:)`, `Label(…, systemImage:)`.
        for row in index.foreignRows(name) {
            guard case .call(_, let label) = row.pattern, labels.contains(label) || (label.isEmpty && !(call.arguments?.arguments.isEmpty ?? true)) else { continue }
            if row.diagnostic == .tooManyArguments { continue }
            let args = call.arguments?.arguments ?? []
            var desk = row.deskText
            for (i, a) in args.enumerated() {
                var value = text(a.value.node)
                if let implicit = ImplicitMemberExprSyntax(a.value.node), let fr = foreignImplicitRow(implicit.name.token.name) {
                    value = fr.deskText
                }
                desk = desk.replacingOccurrences(of: "{\(i)}", with: value)
            }
            var fixIts: [FixIt] = []
            if row.exact, let clause = call.arguments, !desk.contains("{") {
                fixIts.append(fix("replace", [edit(r.lowerBound..<range(clause.node).upperBound, desk)]))
            }
            report(row.diagnostic == .swiftUIComponent ? .swiftUIComponent : row.diagnostic, r,
                   ["desk": .code(desk), "name": .code(name)], fixIts: fixIts, dropped: .element(id(call.node)))
            return true
        }
        guard let row = foreignRows(forName: name).first else { return false }
        reportForeignName(row, at: r, name: name, call: call)
        return true
    }

    /// Assignments that are foreign: INI keys (`IfCondition=…`, DK9301), HTML attributes (`class="x"`, DK9204).
    func foreignAssignment(_ statement: PositionedNode, _ assignment: AssignmentSyntax) -> Bool {
        let path = assignment.target.path
        guard path.count == 1 else { return false }
        let key = path[0]
        let r = range(statement)
        if ["class", "onclick", "onmouseover", "onmouseout", "id", "style", "href", "src"].contains(key),
           assignment.value.node.kind == .stringLiteral {
            let desk = key == "class" || key == "style" ? "style name { … } and .style(name)" : key.hasPrefix("on") ? ".onClick { … }" : ".name(…)"
            report(.htmlAttribute, r, ["attribute": .code(key), "desk": .code(desk)])
            return true
        }
        if assignment.target.name.token.isUpperName, !options.keys.contains(key),
           !index.foreignRows(key).filter({ if case .iniKey = $0.pattern { return true }; return false }).isEmpty
            || catalogDeskName(forRainmeterKey: key) != nil {
            let value = text(assignment.value.node)
            let synthetic = Diagnostic(id: .rainmeterOption, severity: .error, file: file, range: range(assignment.target.node),
                                       arguments: ["name": .code(key), "value": .code(value)])
            if let enriched = enrichIniOption(synthetic) {
                report(enriched.id, enriched.range, enriched.arguments, fixIts: enriched.fixIts)
            }
            return true
        }
        return false
    }

    // MARK: - Members, implicit members, labels, modifiers

    func reportForeignMember(_ row: ForeignSpec, at r: Range<Int>, base: String, name: String, node: Range<Int>) {
        switch row.diagnostic {
        case .olderDeskName:
            let desk = row.deskText
            let short = desk.split(separator: ".").last.map(String.init) ?? desk
            report(.olderDeskName, r, ["new": .code(desk)], fixIts: [fix("replace", [edit(r, short)])])
        case .swiftName:
            let desk = row.deskText.replacingOccurrences(of: "{0}", with: base)
            report(.swiftName, r, ["desk": .code(desk), "swift": .code("\(base).\(name)()")])
        default:
            report(row.diagnostic, r, ["desk": .code(row.deskText), "name": .code(name)])
        }
    }

    func foreignImplicitRow(_ name: String) -> ForeignSpec? {
        index.foreignRows("." + name).first { if case .implicitMember = $0.pattern { return true }; return false }
    }

    func reportForeignImplicit(_ row: ForeignSpec, at r: Range<Int>, name: String) {
        let desk = row.deskText
        let fixIts = row.exact ? [fix("replace", [edit(r, desk)])] : []
        if row.diagnostic == .olderDeskName {
            report(.olderDeskName, r, ["new": .code(desk)], fixIts: fixIts)
        } else {
            report(.swiftName, r, ["desk": .code(desk), "swift": .code("." + name)], fixIts: fixIts)
        }
    }

    func reportForeignLabel(_ row: ForeignSpec, argument: ArgumentSyntax, name: String) {
        let labelRange = range(argument.label!.node)
        if row.diagnostic == .swiftBinding {
            let value = text(argument.value.node).trimmingCharacters(in: CharacterSet(charactersIn: "$"))
            let start = textStart(argument.node)
            mute += 1
            _ = infer(argument.value.node, ExprContext(), expected: nil)
            mute -= 1
            if argument.value.node.kind == .identifierExpr, let decl = decls[IdentifierExprSyntax(unchecked: argument.value.node).name] {
                decl.used = true
            }
            report(.swiftBinding, labelRange, ["name": .code(value)],
                   fixIts: [fix("removeLabels", [edit(start..<textStart(argument.value.node), "")])])
            return
        }
        let desk = row.deskText
        let colonEnd = argument.colon.map { range($0).upperBound } ?? labelRange.upperBound
        report(.swiftName, labelRange, ["desk": .code(desk), "swift": .code(name + ":")],
               fixIts: [fix("replace", [edit(labelRange.lowerBound..<colonEnd, desk)])])
    }

    /// A foreign modifier: `.foregroundColor(…)`, `.fontSize(…)`, `.corner(…)`, `.colour(…)`. Returns true when
    /// reported.
    func reportForeignModifier(_ modifier: ModifierAppSyntax, element: ElementNode?) -> Bool {
        let name = modifier.name.token.name
        let arguments = modifier.arguments?.arguments ?? []
        let rows = index.foreignRows("." + name)
        guard !rows.isEmpty else { return false }
        // A row keyed on an argument wins: `.frame(maxWidth:)`, `.padding(.horizontal, 6)`, `.font(.system(…))`.
        var chosen: ForeignSpec?
        for row in rows {
            guard case .modifierWithArgument(_, let argument) = row.pattern else { continue }
            if argument.hasPrefix(".") {
                if let first = arguments.first, text(first.value.node).hasPrefix(argument) { chosen = row; break }
            } else if arguments.contains(where: { $0.label?.name == argument }) {
                chosen = row
                break
            }
        }
        if chosen == nil {
            chosen = rows.first { row in
                if case .modifier = row.pattern { return row.context != .onElement || element != nil }
                return false
            }
        }
        guard let row = chosen else { return false }
        reportForeignModifierRow(row, modifier: modifier)
        return true
    }

    func reportForeignModifierRow(_ row: ForeignSpec, modifier: ModifierAppSyntax) {
        let name = modifier.name.token.name
        let arguments = modifier.arguments?.arguments ?? []
        let r = range(modifier.node)
        let nameRange = range(modifier.name)
        var desk = row.deskText
        // `{0}`, `{1}`: the arguments as written, their foreign names converted.
        var values: [String] = []
        for argument in arguments {
            var value = text(argument.value.node)
            if let implicit = ImplicitMemberExprSyntax(argument.value.node), let fr = foreignImplicitRow(implicit.name.token.name) {
                value = fr.deskText
            }
            values.append(value)
        }
        if case .modifierWithArgument(_, let argument) = row.pattern, argument.hasPrefix(".") {
            // `.font(.system(size: 13, weight: .bold))`, `.padding(.horizontal, 6)`.
            if let first = arguments.first, first.value.node.kind == .callExpr || first.value.node.kind == .implicitMemberExpr {
                var inner: [String: String] = [:]
                var innerValues: [String] = []
                if let implicit = ImplicitMemberExprSyntax(first.value.node), let clause = implicit.arguments {
                    for a in clause.arguments {
                        var v = text(a.value.node)
                        if let im = ImplicitMemberExprSyntax(a.value.node), let fr = foreignImplicitRow(im.name.token.name) { v = fr.deskText }
                        if let label = a.label?.name { inner[label] = v } else { innerValues.append(v) }
                    }
                }
                let size = inner["size"] ?? "13"
                let weight = inner["weight"] ?? ""
                let design = inner["design"].map { $0 == ".default" ? ".standard" : $0 == ".monospaced" ? ".mono" : $0 } ?? ""
                desk = desk.replacingOccurrences(of: "{size}", with: size)
                desk = desk.replacingOccurrences(of: ", {weight}", with: weight.isEmpty ? "" : ", " + weight)
                desk = desk.replacingOccurrences(of: ", {design}", with: design.isEmpty ? "" : ", " + design)
                if let f = innerValues.first { desk = desk.replacingOccurrences(of: "{0}", with: f) }
            }
        }
        for (i, value) in values.enumerated() { desk = desk.replacingOccurrences(of: "{\(i)}", with: value) }
        if case .modifierWithArgument(_, let argument) = row.pattern, argument == "width" {
            let width = arguments.first { $0.label?.name == "width" }.map { text($0.value.node) } ?? "0"
            let height = arguments.first { $0.label?.name == "height" }.map { text($0.value.node) }
            desk = height.map { ".size(\(width), \($0))" } ?? ".width(\(width))"
        }
        if name == "visible", let first = arguments.first { desk = ".hidden(if: not \(text(first.value.node)))" }
        var exact = row.exact && !desk.contains("{") && !desk.contains("…")
        var nameOnly: String?
        if row.exact, modifier.block != nil, desk.hasPrefix("."), desk.hasSuffix(" { … }") {
            // `.onTap { … }` → `.onClick { … }`: the name changes, the block stays.
            nameOnly = String(desk.dropFirst().dropLast(6))
            exact = false
        }
        switch row.diagnostic {
        case .swiftUIModifier:
            var fixIts: [FixIt] = []
            if desk.isEmpty {
                fixIts.append(fix("remove", [edit(modifier.node.range.lowerBound..<r.upperBound, "")]))
                report(.swiftUIModifier, nameRange, ["name": .code(name), "desk": .code(hintRemoveText(name))], fixIts: fixIts)
            } else {
                if exact { fixIts.append(fix("replace", [edit(r, desk)])) }
                if let nameOnly { fixIts.append(fix("replace", [edit(nameRange, nameOnly)])) }
                report(.swiftUIModifier, nameRange, ["name": .code(name), "desk": .code(desk)], fixIts: fixIts)
            }
        case .otherFrameworkName:
            var fixIts: [FixIt] = exact ? [fix("replace", [edit(r, desk)])] : []
            if let nameOnly { fixIts = [fix("replace", [edit(nameRange, nameOnly)])] }
            report(.otherFrameworkName, nameRange, ["name": .code("." + name), "family": .text(familyName(row.family)), "desk": .code(desk)],
                   fixIts: fixIts)
        case .olderDeskName:
            report(.olderDeskName, nameRange, ["new": .code(desk)], fixIts: exact ? [fix("replace", [edit(r, desk)])] : [])
        case .unknownModifier:
            let suggestion = desk.hasPrefix(".") ? String(desk.dropFirst().prefix { $0.isLetter }) : desk
            report(.unknownModifier, nameRange, ["name": .code(name), "suggestion": .code(suggestion)],
                   fixIts: [fix("fix", [edit(nameRange, suggestion)])])
        default:
            report(row.diagnostic, nameRange, ["name": .code(name), "desk": .code(desk)])
        }
    }

    func hintRemoveText(_ name: String) -> String {
        name == "resizable" ? ".imageMode(…)" : ""
    }
}
